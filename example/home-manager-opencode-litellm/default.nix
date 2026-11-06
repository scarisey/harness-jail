{
  self,
  home-manager,
  pkgs,
  ...
}:
(pkgs.extend self.overlays.default).testers.nixosTest {
  name = "home-manager-opencode-litellm";

  nodes.machine = {
    pkgs,
    lib,
    ...
  }: {
    imports = [
      home-manager.nixosModules.home-manager
    ];

    virtualisation = {
      memorySize = 4096;
      cores = 2;
    };

    users.users.test = {
      isNormalUser = true;
      home = "/home/test";
      linger = true;
    };

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      users.test = {pkgs, ...}: {
        imports = [
          self.homeManagerModules.harness-jail
          self.homeManagerModules.litellm
        ];

        home = {
          username = "test";
          homeDirectory = "/home/test";
          stateVersion = "24.11";
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
            environment = {
              UI_PASSWORD = "changeme";
              LITELLM_MASTER_KEY = "5ad24882a916245c31586c77754900ef232f54fdc22589108947ee2ace1b4bfb";
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
        };
      };
    };

    services.postgresql = {
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

    environment.systemPackages = [pkgs.curl];
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("postgresql.service")
    machine.wait_for_unit("home-manager-test.service")
    machine.wait_for_unit("litellm.service", user="test")
    machine.wait_for_open_port(4000)
    machine.succeed("curl -fsS http://127.0.0.1:4000/health/liveliness")
    machine.succeed("sudo -u postgres psql -d litellm -tAc \"SELECT count(*) FROM _prisma_migrations\"")
    machine.succeed("test -d /home/test/.local/share/litellm/ui")
    machine.succeed("su - test -c 'litellm --version'")
    machine.succeed("su - test -c 'harness --version'")
  '';
}
