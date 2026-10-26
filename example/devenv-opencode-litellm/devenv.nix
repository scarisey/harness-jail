{
  inputs,
  pkgs,
  lib,
  ...
}: {
  overlays = [
    inputs.opencode.overlays.default
  ];
  packages = with pkgs; [
    opencode
  ];
  services = {
    harness-jail = {
      enable = true;
      package = pkgs.opencode;
      command = "opencode";
      enableNetwork = true;
      args = ["serve"];
      clearEnv = true;
      readWritePaths = [
        ../../.
      ];
      homeDir = ./.home;
    };

    litellm = {
      enable = true;
      environment = {
        UI_PASSWORD = "changeme";
        LITELLM_MASTER_KEY = "5ad24882a916245c31586c77754900ef232f54fdc22589108947ee2ace1b4bfb";
        LITELLM_SALT_KEY = "ed70fcbadd9bc1033dc41eb1987cb0cf64994c3e0950c85f154298ad7669ba51";
        DATABASE_URL = "postgresql://litellm:litellm@127.0.0.1:5433/litellm";
        STORE_MODEL_IN_DB = "True";
        SCARF_NO_ANALYTICS = "True";
        DO_NOT_TRACK = "True";
        ANONYMIZED_TELEMETRY = "False";
        LITELLM_LOG = "INFO";
      };
      extraFlags = [
        "--detailed_debug"
      ];
    };

    postgres = {
      enable = true;
      listen_addresses = "127.0.0.1";
      port = 5433;
      hbaConf = lib.mkForce ''
        local all all trust
        host all all 127.0.0.1/32 trust
        host all all ::1/128 trust
      '';
      initialDatabases = [
        {
          name = "litellm";
          pass = "litellm";
          user = "litellm";
        }
      ];
    };
  };
}
