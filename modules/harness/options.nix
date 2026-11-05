{
  lib,
  pkgs,
}: let
  inherit (lib) literalExpression mkEnableOption mkOption types;
in {
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

    package = mkOption {
      type = types.package;
      description = "Nix package providing the CLI to wrap (for example pkgs.opencode).";
      example = literalExpression "pkgs.opencode";
    };

    command = mkOption {
      type = types.str;
      description = "Executable name or path to run inside the sandbox.";
      example = "opencode";
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [
        pkgs.bashNonInteractive
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gnused
        pkgs.gawk
        pkgs.findutils
        pkgs.diffutils
        pkgs.gnutar
        pkgs.gzip
        pkgs.which
        pkgs.git
        pkgs.curl
        pkgs.ripgrep
      ];
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
}
