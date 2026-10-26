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
        type = types.strMatching "[A-Za-z0-9._-]+";
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
        description = "Shell-compatible file of environment variables loaded by the wrapper and passed into the sandbox.";
      };

      homeDir = mkOption {
        type = types.path;
        description = "Dedicated persistent home directory for the sandboxed executable.";
      };
    };
  };

  # f : { cfg, bwrapCommand } -> nixConfig
  mkConfig = config: f: let
    cfg = config.services.harness-jail;
    readOnlyPathsFinal = lib.unique (map (p: builtins.toString p) cfg.readOnlyPaths);
    readWritePathsFinal = lib.unique (map (p: builtins.toString p) (
      cfg.readWritePaths ++ [cfg.homeDir] ++ lib.optional (builtins.hasAttr "devenv" config) config.devenv.root
    ));
    packageFinal = pkgs.writeShellScriptBin cfg.wrapperName ''
      export PATH="${lib.makeBinPath ([cfg.package] ++ cfg.extraPackages)}''${PATH:+:$PATH}"
      exec ${lib.escapeShellArg cfg.command} "$@"
    '';

    bwrapPrefixArgs =
      [
        "--unshare-all"
        "--die-with-parent"
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
    environment =
      optionalAttrs cfg.clearEnv {
        HOME = builtins.toString cfg.homeDir;
        PATH = lib.makeBinPath (cfg.extraPackages ++ [cfg.package]);
        SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      }
      // cfg.environment;
    environmentArgs = concatLists (mapAttrsToList (name: value: ["--setenv" name value]) environment);
    bwrapSuffixArgs =
      concatLists (map (path: ["--ro-bind" path path]) readOnlyPathsFinal)
      ++ concatLists (map (path: ["--bind" path path]) readWritePathsFinal)
      ++ optional cfg.enableNetwork "--share-net";

    wrappedCommand = "${packageFinal}/bin/${cfg.wrapperName}";
    bwrapArgs =
      bwrapPrefixArgs
      ++ environmentArgs
      ++ bwrapSuffixArgs
      ++ ["--" wrappedCommand]
      ++ cfg.args;
    bwrapCommand =
      if cfg.environmentFile == null
      then "${pkgs.bubblewrap}/bin/bwrap ${escapeShellArgs bwrapArgs}"
      else if !cfg.clearEnv
      then "${pkgs.writeShellScript "bwrap-harness" ''
        set -eo pipefail
        set -a
        . ${escapeShellArg cfg.environmentFile}
        set +a
        exec ${pkgs.bubblewrap}/bin/bwrap ${escapeShellArgs bwrapArgs} "$@"
      ''}"
      else let
        innerScript = pkgs.writeShellScript "bwrap-harness-inner" ''
          set -eo pipefail
          set -a
          . "$1"
          shift
          set +a
          unset PWD SHLVL _
          bwrap_args=(${escapeShellArgs bwrapPrefixArgs})
          while IFS= read -r -d "" entry; do
            bwrap_args+=(--setenv "''${entry%%=*}" "''${entry#*=}")
          done < <(${pkgs.coreutils}/bin/env -0)
          bwrap_args+=(${escapeShellArgs environmentArgs})
          bwrap_args+=(${escapeShellArgs bwrapSuffixArgs})
          bwrap_args+=(-- ${escapeShellArgs ([wrappedCommand] ++ cfg.args)} "$@")
          exec ${pkgs.bubblewrap}/bin/bwrap "''${bwrap_args[@]}"
        '';
      in "${pkgs.writeShellScript "bwrap-harness" ''
        exec ${pkgs.coreutils}/bin/env -i ${pkgs.bash}/bin/bash --noprofile --norc ${innerScript} ${escapeShellArg cfg.environmentFile} "$@"
      ''}";
  in
    mkIf cfg.enable (f {inherit cfg bwrapCommand;});
in {
  inherit mkOptions mkConfig;
}
