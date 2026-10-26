{
  self,
  pkgs,
  lib ? pkgs.lib,
  ...
}:
pkgs.testers.nixosTest {
  name = "nixos-opencode-litellm";

  nodes.machine = {
    pkgs,
    lib,
    ...
  }: {
    disabledModules = [
      "services/misc/litellm.nix"
    ];

    imports = [
      self.nixosModules.harness-jail
      self.nixosModules.litellm
    ];

    virtualisation = {
      memorySize = 4096;
      cores = 2;
    };

    services = {
      harness-jail = {
        enable = true;
        package = pkgs.opencode;
        command = "opencode";
        enableNetwork = true;
        args = ["serve"];
        clearEnv = true;
      };

      litellm = {
        enable = true;
        environmentFile = "/run/litellm.env";
        environment = {
          UI_PASSWORD = "changeme";
          LITELLM_SALT_KEY = "ed70fcbadd9bc1033dc41eb1987cb0cf64994c3e0950c85f154298ad7669ba51";
          DATABASE_URL = "postgresql://litellm:litellm@127.0.0.1:5432/litellm";
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

      postgresql = {
        enable = true;
        authentication = lib.mkForce ''
          local all all trust
          host all all 127.0.0.1/32 trust
          host all all ::1/128 trust
        '';
        initialScript = pkgs.writeText "litellm-init.sql" ''
          CREATE ROLE litellm WITH LOGIN PASSWORD 'litellm' SUPERUSER;
          CREATE DATABASE litellm OWNER litellm;
        '';
      };
    };

    systemd.tmpfiles.rules = [
      "f /run/litellm.env 0644 root root - LITELLM_MASTER_KEY=5ad24882a916245c31586c77754900ef232f54fdc22589108947ee2ace1b4bfb"
    ];

    environment.systemPackages = [pkgs.curl];
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("postgresql.service")
    machine.wait_for_unit("litellm.service")
    machine.wait_for_open_port(4000)
    machine.succeed("curl -fsS http://127.0.0.1:4000/health/liveliness")
    machine.succeed("harness --version")
  '';
}
