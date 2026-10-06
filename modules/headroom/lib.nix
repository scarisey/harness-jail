{
  pkgs,
  lib,
}: let
  defaultPackage = pkgs.callPackage ../../packages/headroom {};
in rec {
  mkOptions = {
    enable = lib.mkEnableOption "Headroom optimization proxy (sandboxed via Bubblewrap)";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      defaultText = lib.literalExpression "pkgs.callPackage ../../packages/headroom {}";
      description = "Headroom package to run.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address the proxy listens on.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8787;
      description = "Port the proxy listens on.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {
        HEADROOM_MODE = "cache";
        ANTHROPIC_API_KEY = "sk-ant-...";
      };
      description = "Environment variables passed to Headroom.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/headroom.env";
      description = ''
        Shell-compatible file of environment variables (for example provider
        API keys) loaded inside the sandbox. The file is read at runtime and is
        not copied into the Nix store.
      '';
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["--mode" "cache"];
      description = "Additional arguments passed to `headroom proxy`.";
    };

    readOnlyPaths = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [];
      description = "Extra host paths mounted read-only at the same path in the sandbox.";
    };

    readWritePaths = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [];
      description = "Extra host paths mounted read-write at the same path in the sandbox.";
    };
  };

  buildScript = {
    cfg,
    stateDir,
  }: let
    proxyCommand =
      [
        "${cfg.package}/bin/headroom"
        "proxy"
        "--host"
        cfg.host
        "--port"
        (toString cfg.port)
      ]
      ++ cfg.extraFlags;

    environmentAssignments =
      lib.mapAttrsToList (
        name: value: "${name}=${value}"
      )
      cfg.environment;

    command =
      if cfg.environmentFile == null
      then proxyCommand
      else [
        "${pkgs.bashNonInteractive}/bin/sh"
        "-c"
        ''
          set -a
          . /etc/headroom/env
          set +a
          exec ${pkgs.coreutils}/bin/env ${lib.escapeShellArgs environmentAssignments} ${lib.escapeShellArgs proxyCommand}
        ''
      ];

    envFlags = lib.concatLists (
      lib.mapAttrsToList (name: value: ["--setenv" name value]) cfg.environment
    );

    envFileBindFlags = lib.optionals (cfg.environmentFile != null) [
      "--ro-bind"
      (toString cfg.environmentFile)
      "/etc/headroom/env"
    ];

    readOnlyBindFlags = lib.concatLists (
      map (path: ["--ro-bind" (toString path) (toString path)]) cfg.readOnlyPaths
    );

    readWriteBindFlags = lib.concatLists (
      map (path: ["--bind" (toString path) (toString path)]) cfg.readWritePaths
    );

    bwrapArgs =
      [
        "--unshare-all"
        "--share-net"
        "--die-with-parent"
        "--new-session"
        "--proc"
        "/proc"
        "--dev"
        "/dev"
        "--tmpfs"
        "/tmp"
        "--ro-bind"
        "/nix/store"
        "/nix/store"
        "--ro-bind"
        "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "/etc/ssl/certs/ca-certificates.crt"
        "--ro-bind"
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
        "--symlink"
        "${pkgs.bashNonInteractive}/bin/sh"
        "/bin/sh"
        "--symlink"
        "${pkgs.coreutils}/bin/env"
        "/usr/bin/env"
        "--chdir"
        "/tmp/headroom-state"
        "--clearenv"
        "--setenv"
        "PATH"
        "${cfg.package}/bin:${pkgs.coreutils}/bin"
        "--setenv"
        "HOME"
        "/tmp/headroom-state"
        "--setenv"
        "HEADROOM_WORKSPACE_DIR"
        "/tmp/headroom-state"
        "--setenv"
        "HEADROOM_CONFIG_DIR"
        "/tmp/headroom-state/config"
        "--setenv"
        "SSL_CERT_FILE"
        "/etc/ssl/certs/ca-certificates.crt"
        "--setenv"
        "REQUESTS_CA_BUNDLE"
        "/etc/ssl/certs/ca-certificates.crt"
        "--setenv"
        "PYTHONUNBUFFERED"
        "1"
      ]
      ++ envFileBindFlags
      ++ envFlags
      ++ readOnlyBindFlags
      ++ readWriteBindFlags;
  in
    pkgs.writeShellScriptBin "headroom-proxy" ''
      set -euo pipefail

      HEADROOM_STATE_DIR="${stateDir}"
      mkdir -p "$HEADROOM_STATE_DIR"

      exec ${pkgs.bubblewrap}/bin/bwrap ${lib.escapeShellArgs bwrapArgs} \
        --bind "$HEADROOM_STATE_DIR" /tmp/headroom-state \
        -- ${lib.escapeShellArgs command}
    '';
}
