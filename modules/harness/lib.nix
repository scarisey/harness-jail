{
  lib,
  pkgs,
}:
with lib; let
  mkOptions = {
    services.harness-jail = {
      enable = mkEnableOption "Activate LLM harness sandboxing.";

      daemon = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether the harness runs as a long-lived systemd service. When false,
          no systemd unit is created and the harness is only available through
          the wrapper. Ignored by the devenv module, which never starts a
          service.
        '';
      };

      wrapperName = mkOption {
        type = types.strMatching "[A-Za-z0-9][A-Za-z0-9._-]*";
        default = "harness";
        description = "Name of the wrapper command installed on PATH.";
      };

      package = lib.mkOption {
        type = lib.types.package;
        description = "Nix package providing the CLI to wrap (for example pkgs.opencode).";
        example = lib.literalExpression "pkgs.opencode";
      };

      command = lib.mkOption {
        type = lib.types.str;
        description = "Executable name or path to run inside the sandbox.";
        example = "opencode";
      };

      extraPackages = mkOption {
        type = types.listOf types.package;
        default = with pkgs; [bashNonInteractive coreutils gnugrep gnused gawk findutils diffutils gnutar gzip which git curl ripgrep];
        defaultText = literalExpression "[ bashNonInteractive coreutils gnugrep gnused gawk findutils diffutils gnutar gzip which git curl ripgrep ]";
        description = ''
          Tools made available on PATH inside the sandbox (from the read-only Nix store).
          /bin/sh and /usr/bin/env are provided as symlinks to Nix store binaries.
          No setuid binaries (sudo, su) or host /usr, /bin, /etc contents are exposed.
        '';
      };

      args = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Arguments passed to the executable.";
      };

      enableNetwork = mkOption {
        type = types.bool;
        default = false;
        description = "Enable network access.";
      };

      readOnlyPaths = mkOption {
        type = types.listOf types.path;
        default = [];
        description = "Host paths mounted read-only at the same path inside the sandbox.";
      };

      readWritePaths = mkOption {
        type = types.listOf types.path;
        default = [];
        description = "Host paths mounted read-write at the same path inside the sandbox.";
      };

      clearEnv = mkOption {
        type = types.bool;
        default = true;
        description = "Discard the host environment before starting the sandbox.";
      };

      environment = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Environment variables set inside the sandbox. With clearEnv enabled, HOME defaults to homeDir unless overridden here.";
      };

      environmentFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Shell-compatible file of environment variables loaded by the wrapper
          and passed into the sandbox. The file is masked inside the sandbox so
          it cannot be read there, even if it lives under a mounted path.
        '';
      };

      homeDir = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Dedicated persistent home directory for the sandboxed executable.
          When null, the wrapper uses a per-user state directory at runtime
          (`''${XDG_STATE_HOME:-$HOME/.local/state}/harness-jail`).
        '';
      };
    };
  };

  # f : { cfg, bwrapCommand } -> nixConfig
  mkConfigFor = config: cfg: f: let
    staticHomeDir = cfg.homeDir != null;
    homeDirStr = optionalString staticHomeDir (toString cfg.homeDir);
    readOnlyPathsFinal = lib.unique (map (p: builtins.toString p) cfg.readOnlyPaths);
    readWritePathsFinal = lib.unique (map (p: builtins.toString p) (
      cfg.readWritePaths
      ++ lib.optional staticHomeDir cfg.homeDir
      ++ lib.optional (builtins.hasAttr "devenv" config) config.devenv.root
    ));
    packageFinal = pkgs.writeShellScriptBin cfg.wrapperName ''
      export PATH="${lib.makeBinPath ([cfg.package] ++ cfg.extraPackages)}''${PATH:+:$PATH}"
      exec ${lib.escapeShellArg cfg.command} "$@"
    '';

    bwrapPrefixArgs =
      [
        "--unshare-all"
        "--die-with-parent"
        "--new-session"
        "--dev"
        "/dev"
        "--proc"
        "/proc"
        "--tmpfs"
        "/tmp"
        "--ro-bind"
        "/nix/store"
        "/nix/store"
        "--ro-bind-try"
        "/etc/resolv.conf"
        "/etc/resolv.conf"
        "--ro-bind-try"
        "/etc/hosts"
        "/etc/hosts"
        "--ro-bind-try"
        "/etc/nsswitch.conf"
        "/etc/nsswitch.conf"
        "--ro-bind-try"
        "/etc/os-release"
        "/etc/os-release"
        "--ro-bind"
        "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "/etc/ssl/certs/ca-certificates.crt"
        "--symlink"
        "${pkgs.bashNonInteractive}/bin/sh"
        "/bin/sh"
        "--symlink"
        "${pkgs.coreutils}/bin/env"
        "/usr/bin/env"
        "--cap-drop"
        "ALL"
      ]
      ++ optional cfg.clearEnv "--clearenv";

    # Built-in defaults intentionally exclude HOME. It is emitted before the
    # environment file so the file can override it, while explicit
    # cfg.environment values are emitted afterwards and still win.
    defaultEnvironment = optionalAttrs cfg.clearEnv {
      PATH = lib.makeBinPath (cfg.extraPackages ++ [cfg.package]);
      SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      REQUESTS_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
      CURL_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
    };
    defaultEnvironmentArgs = concatLists (mapAttrsToList (name: value: ["--setenv" name value]) defaultEnvironment);
    userEnvironmentArgs = concatLists (mapAttrsToList (name: value: ["--setenv" name value]) cfg.environment);

    homeEnvironmentArg =
      if !cfg.clearEnv
      then ""
      else if staticHomeDir
      then escapeShellArgs ["--setenv" "HOME" homeDirStr]
      else ''--setenv HOME "$HARNESS_JAIL_HOME"'';

    homeBindArg =
      if staticHomeDir
      then ""
      else ''--bind "$HARNESS_JAIL_HOME" "$HARNESS_JAIL_HOME"'';

    homeDirSetup = optionalString (!staticHomeDir) ''
      HARNESS_JAIL_HOME="''${XDG_STATE_HOME:-$HOME/.local/state}/harness-jail"
      umask 077
      mkdir -p "$HARNESS_JAIL_HOME"
    '';

    bwrapSuffixArgs =
      concatLists (map (path: ["--ro-bind" path path]) readOnlyPathsFinal)
      ++ concatLists (map (path: ["--bind" path path]) readWritePathsFinal)
      ++ optional cfg.enableNetwork "--share-net";

    # The wrapper sources the file outside the sandbox. Mask it afterwards so
    # a process inside cannot read the secrets from a mounted directory.
    environmentFileMaskArgs = optionals (cfg.environmentFile != null) [
      "--ro-bind"
      (toString pkgs.emptyFile)
      cfg.environmentFile
    ];

    wrappedCommand = "${packageFinal}/bin/${cfg.wrapperName}";

    bwrapCommand =
      if cfg.environmentFile == null
      then "${pkgs.writeShellScript "bwrap-harness" ''
        set -eo pipefail
        ${homeDirSetup}
        exec ${pkgs.bubblewrap}/bin/bwrap \
          ${escapeShellArgs bwrapPrefixArgs} \
          ${homeEnvironmentArg} \
          ${escapeShellArgs defaultEnvironmentArgs} \
          ${escapeShellArgs userEnvironmentArgs} \
          ${homeBindArg} \
          ${escapeShellArgs bwrapSuffixArgs} \
          ${escapeShellArgs environmentFileMaskArgs} \
          -- ${escapeShellArgs ([wrappedCommand] ++ cfg.args)} "$@"
      ''}"
      else if !cfg.clearEnv
      then "${pkgs.writeShellScript "bwrap-harness" ''
        set -eo pipefail
        ${homeDirSetup}
        set -a
        . ${escapeShellArg cfg.environmentFile}
        set +a
        exec ${pkgs.bubblewrap}/bin/bwrap \
          ${escapeShellArgs bwrapPrefixArgs} \
          ${homeEnvironmentArg} \
          ${escapeShellArgs defaultEnvironmentArgs} \
          ${escapeShellArgs userEnvironmentArgs} \
          ${homeBindArg} \
          ${escapeShellArgs bwrapSuffixArgs} \
          ${escapeShellArgs environmentFileMaskArgs} \
          -- ${escapeShellArgs ([wrappedCommand] ++ cfg.args)} "$@"
      ''}"
      else let
        innerScript = pkgs.writeShellScript "bwrap-harness-inner" ''
          set -eo pipefail
          set -a
          . "$1"
          shift
          set +a
          unset PWD SHLVL _
          ${optionalString (!staticHomeDir) ''
            sandbox_home="$HARNESS_JAIL_HOME"
            unset HARNESS_JAIL_HOME
          ''}
          bwrap_args=(${escapeShellArgs bwrapPrefixArgs})
          ${optionalString staticHomeDir ''
            bwrap_args+=(${escapeShellArgs ["--setenv" "HOME" homeDirStr]})
          ''}
          ${optionalString (!staticHomeDir) ''
            bwrap_args+=(--setenv HOME "$sandbox_home")
          ''}
          bwrap_args+=(${escapeShellArgs defaultEnvironmentArgs})
          while IFS= read -r -d "" entry; do
            bwrap_args+=(--setenv "''${entry%%=*}" "''${entry#*=}")
          done < <(${pkgs.coreutils}/bin/env -0)
          bwrap_args+=(${escapeShellArgs userEnvironmentArgs})
          ${optionalString (!staticHomeDir) ''
            bwrap_args+=(--bind "$sandbox_home" "$sandbox_home")
          ''}
          bwrap_args+=(${escapeShellArgs bwrapSuffixArgs})
          bwrap_args+=(${escapeShellArgs environmentFileMaskArgs})
          bwrap_args+=(-- ${escapeShellArgs ([wrappedCommand] ++ cfg.args)} "$@")
          exec ${pkgs.bubblewrap}/bin/bwrap "''${bwrap_args[@]}"
        '';
      in "${pkgs.writeShellScript "bwrap-harness" ''
        set -eo pipefail
        ${homeDirSetup}
        exec ${pkgs.coreutils}/bin/env -i \
          ${optionalString (!staticHomeDir) ''HARNESS_JAIL_HOME="$HARNESS_JAIL_HOME"''} \
          ${pkgs.bash}/bin/bash --noprofile --norc ${innerScript} ${escapeShellArg cfg.environmentFile} "$@"
      ''}";
  in
    mkIf cfg.enable (f {inherit cfg bwrapCommand;});
in {
  inherit mkOptions mkConfigFor;

  mkConfig = config: f: mkConfigFor config config.services.harness-jail f;
}
