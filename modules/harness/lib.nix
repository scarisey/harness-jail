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
        type = types.str;
        default = "harness";
        description = "How to call the wrapper.";
      };

      package = lib.mkOption {
        type = lib.types.package;
        description = "Nix package providing the CLI to wrap (for example pkgs.opencode).";
        example = lib.literalExpression "pkgs.opencode";
      };

      command = lib.mkOption {
        type = lib.types.str;
        description = "CLI executable name. Defaults to the package's main program.";
        example = "opencode";
      };

      extraPackages = mkOption {
        type = types.listOf types.package;
        default = with pkgs; [bashNonInteractive coreutils gnugrep gnused gawk findutils diffutils gnutar gzip which git curl ripgrep];
        defaultText = literalExpression "[ bash coreutils gnugrep gnused gawk findutils diffutils gnutar gzip which git curl ripgrep ]";
        description = ''
          Tools made available on PATH inside the sandbox (from the read-only Nix store).
          /bin/sh and /usr/bin/env are provided as symlinks to Nix store binaries.
          No setuid binaries (sudo, su) or host /usr, /bin, /etc contents are exposed.
        '';
      };

      args = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Arguments passed to exectuable.";
      };

      enableNetwork = mkOption {
        type = types.bool;
        default = false;
        description = "Enable network access.";
      };

      readOnlyPaths = mkOption {
        type = types.listOf types.path;
        default = [];
        description = "Paths that would be read by harness.";
      };

      readWritePaths = mkOption {
        type = types.listOf types.path;
        default = [];
        description = "Paths that would be read/written by harness.";
      };

      clearEnv = mkOption {
        type = types.bool;
        default = true;
        description = "Don't heritate from host environment variables.";
      };

      environment = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Specific environment variables. With clearEnv enabled, HOME defaults to /tmp unless overridden here.";
      };

      environmentFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Shell-compatible file of environment variables to load for the sandboxed executable.";
      };

      homeDir = mkOption {
        type = types.path;
        description = "Path to a dedicated home directory for harness.";
      };
    };
  };

  # f : { cfg, bwrapCommand } -> nixConfig
  mkConfig = config: f: let
    cfg = config.services.harness-jail;
    readWritePathsFinal = map (p: builtins.toString p) (cfg.readWritePaths ++ [cfg.homeDir] ++ lib.optional (builtins.hasAttr "devenv" config) config.devenv.root);
    packageFinal = pkgs.writeShellScriptBin cfg.wrapperName ''
      export PATH="${lib.makeBinPath ([cfg.package] ++ cfg.extraPackages)}''${PATH:+:$PATH}"
      exec "${lib.escapeShellArg cfg.command}" "$@"
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
        "/nix"
        "/nix"
        "--ro-bind"
        "/etc/resolv.conf"
        "/etc/resolv.conf"
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
      concatLists (map (path: ["--ro-bind" path path]) cfg.readOnlyPaths)
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
      else let
        bwrapWrapper = pkgs.writeShellScript "bwrap-harness" ''
          set -eo pipefail
          ${optionalString cfg.clearEnv ''
            exec ${pkgs.coreutils}/bin/env -i ${pkgs.bash}/bin/bash --noprofile --norc -c '
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
            ' bwrap-harness ${escapeShellArg cfg.environmentFile} "$@"
          ''}
          ${optionalString (!cfg.clearEnv) ''
            set -a
            . ${escapeShellArg cfg.environmentFile}
            set +a
            exec ${pkgs.bubblewrap}/bin/bwrap ${escapeShellArgs bwrapArgs} "$@"
          ''}
        '';
      in "${bwrapWrapper}";
  in
    mkIf cfg.enable (f {inherit cfg bwrapCommand;});
in {
  inherit mkOptions mkConfig;
}
