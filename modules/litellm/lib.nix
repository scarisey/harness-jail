{
  pkgs,
  lib,
}: let
  jsonFormat = pkgs.formats.json {};
in rec {
  mkOptions = {
    enable = lib.mkEnableOption "Service proxy LiteLLM (sandboxed via Bubblewrap)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.litellm;
      description = ''
        LiteLLM package to run. The default requires harness-jail's overlay,
        which provides a LiteLLM build with the full proxy dependency set.
        Custom packages must expose the proxy server and may expose
        `passthru.pythonPath` for extra Python modules.
      '';
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address the HTTP server listens on.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 4000;
      description = "Port the HTTP server listens on.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        SCARF_NO_ANALYTICS = "True";
        DO_NOT_TRACK = "True";
        ANONYMIZED_TELEMETRY = "False";
      };
      example = {LITELLM_LOG = "INFO";};
      description = "Environment variables passed to LiteLLM.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/src/secrets/litellm.env";
      description = ''
        Path to an environment (.env) file containing secrets (API keys,
        DATABASE_URL). The file is bind-mounted at /etc/litellm/env and sourced
        inside the sandbox.
      '';
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Additional arguments passed to the `litellm` command.";
    };

    settings = lib.mkOption {
      inherit (jsonFormat) type;
      default = {};
      description = "Configuration as a Nix structure injected into LiteLLM.";
    };
  };

  buildScript = {
    cfg,
    stateDir,
  }: let
    packageFinal =
      lib.warnIf (!(cfg.package ? isLiteLLMProxy))
      "services.litellm.package is not harness-jail's full LiteLLM build. Import harness-jail.overlays.default to get the proxy dependencies and generated Prisma client."
      cfg.package;

    configFile = jsonFormat.generate "litellm-config.json" cfg.settings;

    environmentAssignments = lib.mapAttrsToList (name: value: "${name}=${value}") cfg.environment;

    envFlags = lib.concatLists (
      lib.mapAttrsToList (name: value: ["--setenv" name (toString value)]) cfg.environment
    );

    envFileBindFlags = lib.optionals (cfg.environmentFile != null) [
      "--ro-bind"
      cfg.environmentFile
      "/etc/litellm/env"
    ];

    # An empty regular file works on `nodev` filesystems, unlike /dev/null.
    envFileMaskFlags = lib.optionals (cfg.environmentFile != null) [
      "--ro-bind"
      (toString pkgs.emptyFile)
      cfg.environmentFile
    ];

    # Use the Prisma CLI and engines that were used to build the package when
    # available, so a package from another nixpkgs cannot drift from them.
    prismaEngines = packageFinal.prismaEngines or pkgs.prisma-engines_6;
    prismaCli = packageFinal.prisma or pkgs.prisma_6;
    queryEnginePath = "${prismaEngines}/bin/query-engine";
    schemaEnginePath = "${prismaEngines}/bin/schema-engine";

    litellmCommand =
      [
        "${packageFinal}/bin/litellm"
        "--config"
        "/etc/litellm/config.json"
        "--host"
        cfg.host
        "--port"
        (toString cfg.port)
      ]
      ++ cfg.extraFlags;

    command =
      if cfg.environmentFile == null
      then litellmCommand
      else [
        "${pkgs.bashNonInteractive}/bin/bash"
        "-c"
        ''
          set -a
          . /etc/litellm/env
          set +a
          exec ${pkgs.coreutils}/bin/env ${lib.escapeShellArgs environmentAssignments} ${lib.escapeShellArgs litellmCommand}
        ''
      ];

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
        "${configFile}"
        "/etc/litellm/config.json"
        "--symlink"
        "${pkgs.bashNonInteractive}/bin/sh"
        "/bin/sh"
        "--symlink"
        "${pkgs.coreutils}/bin/env"
        "/usr/bin/env"
        "--clearenv"
        "--setenv"
        "PATH"
        "${packageFinal}/bin:${prismaEngines}/bin:${prismaCli}/bin:${pkgs.coreutils}/bin:${lib.getBin pkgs.openssl}/bin"
        "--setenv"
        "HOME"
        "/tmp/litellm-state"
        "--setenv"
        "LITELLM_NON_ROOT"
        "true"
        "--setenv"
        "LITELLM_UI_PATH"
        "/tmp/litellm-state/ui"
        "--setenv"
        "SSL_CERT_FILE"
        "/etc/ssl/certs/ca-certificates.crt"
        "--setenv"
        "REQUESTS_CA_BUNDLE"
        "/etc/ssl/certs/ca-certificates.crt"
        "--setenv"
        "CURL_CA_BUNDLE"
        "/etc/ssl/certs/ca-certificates.crt"
        "--setenv"
        "PYTHONUNBUFFERED"
        "1"
        "--setenv"
        "PRISMA_OFFLINE_MODE"
        "true"
        "--setenv"
        "PRISMA_CLI_PATH"
        "${prismaCli}/bin/prisma"
        "--setenv"
        "PRISMA_QUERY_ENGINE_BINARY"
        queryEnginePath
        "--setenv"
        "PRISMA_SCHEMA_ENGINE_BINARY"
        schemaEnginePath
        "--cap-drop"
        "ALL"
      ]
      ++ envFileBindFlags
      ++ envFileMaskFlags
      ++ envFlags
      ++ lib.optionals (packageFinal ? pythonPath) [
        "--setenv"
        "PYTHONPATH"
        packageFinal.pythonPath
      ];
  in
    pkgs.writeShellScriptBin "litellm-sandboxed" ''
      set -euo pipefail

      LITELLM_STATE_DIR="${stateDir}"
      mkdir -p "$LITELLM_STATE_DIR/ui"

      exec ${pkgs.bubblewrap}/bin/bwrap ${lib.escapeShellArgs bwrapArgs} \
        --bind "$LITELLM_STATE_DIR" /tmp/litellm-state \
        --chdir /tmp/litellm-state \
        -- ${lib.escapeShellArgs command}
    '';
}
