{
  pkgs,
  lib,
}: let
  jsonFormat = pkgs.formats.json {};
  prismaOverlay = pkgs.callPackage ../../packages/litellm-prisma {};
in rec {
  mkOptions = {
    enable = lib.mkEnableOption "Service proxy LiteLLM (sandboxed via Bubblewrap)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.litellm;
      description = "Paquet LiteLLM à exécuter.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Adresse IP/Hôte d'écoute du serveur HTTP.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 4000;
      description = "Port d'écoute du serveur HTTP.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {LITELLM_LOG = "INFO";};
      description = "Variables d'environnement passées à LiteLLM.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/var/src/secrets/litellm.env";
      description = "Chemin vers un fichier d'environnement (.env) contenant les secrets (clés API, DATABASE_URL).";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Arguments supplémentaires transmis à la commande `litellm`.";
    };

    settings = lib.mkOption {
      type = jsonFormat.type;
      default = {};
      description = "Configuration sous forme de structure Nix injectée dans LiteLLM.";
    };
  };

  buildScript = {
    cfg,
    stateDir,
  }: let
    configFile = jsonFormat.generate "litellm-config.json" cfg.settings;

    envFlags = lib.concatLists (
      lib.mapAttrsToList (name: value: ["--setenv" name (toString value)]) cfg.environment
    );

    envFileBindFlags = lib.optionals (cfg.environmentFile != null) [
      "--ro-bind"
      (toString cfg.environmentFile)
      "/etc/litellm/env"
    ];

    # Binaires Prisma compilés et patchés pour Nix
    prismaEngines = pkgs.prisma-engines_6;
    queryEnginePath = "${prismaEngines}/bin/query-engine";
    schemaEnginePath = "${prismaEngines}/bin/schema-engine";
  in
    pkgs.writeShellScriptBin "litellm-sandboxed" ''
      set -euo pipefail

      LITELLM_STATE_DIR="${stateDir}"
      mkdir -p "$LITELLM_STATE_DIR"

      ${lib.optionalString (cfg.environmentFile != null) ''
        if [ -f "/etc/litellm/env" ]; then
          set -o allexport
          source "/etc/litellm/env"
          set +o allexport
        fi
      ''}

      exec ${pkgs.bubblewrap}/bin/bwrap \
        --unshare-all \
        --share-net \
        --die-with-parent \
        --new-session \
        --proc /proc \
        --dev /dev \
        --tmpfs /tmp \
        --ro-bind /nix/store /nix/store \
        --ro-bind /etc/ssl/certs /etc/ssl/certs \
        --ro-bind /etc/resolv.conf /etc/resolv.conf \
        --ro-bind-try /etc/hosts /etc/hosts \
        --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf \
        --ro-bind-try /etc/os-release /etc/os-release \
        --ro-bind "${configFile}" /etc/litellm/config.json \
        ${lib.concatStringsSep " " envFileBindFlags} \
        --bind "$LITELLM_STATE_DIR" /tmp/litellm-state \
        --chdir /tmp/litellm-state \
        --clearenv \
        --setenv PATH "${cfg.package}/bin:${prismaEngines}/bin:${pkgs.prisma_6}/bin:${pkgs.coreutils}/bin:${lib.getBin pkgs.openssl}/bin" \
        --setenv HOME /tmp/litellm-state \
        --setenv PYTHONUNBUFFERED 1 \
        --setenv PRISMA_OFFLINE_MODE true \
        --setenv PRISMA_CLI_PATH "${pkgs.prisma_6}/bin/prisma" \
        --setenv PYTHONPATH "${prismaOverlay}/${pkgs.python3.sitePackages}:${prismaOverlay.pythonPath}" \
        --setenv PRISMA_QUERY_ENGINE_BINARY "${queryEnginePath}" \
        --setenv PRISMA_SCHEMA_ENGINE_BINARY "${schemaEnginePath}" \
        ${lib.concatStringsSep " " envFlags} \
        ${cfg.package}/bin/litellm \
          --config /etc/litellm/config.json \
          --host ${cfg.host} \
          --port ${toString cfg.port} ${lib.concatStringsSep " " cfg.extraFlags}
    '';
}
