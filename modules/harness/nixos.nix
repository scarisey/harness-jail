{
  config,
  lib,
  pkgs,
  ...
}: let
  bwrapModule = import ./lib.nix {inherit lib pkgs;};
  cfg = config.services.harness-jail;
  serviceName = "harness-jail";
  stateDir = "/var/lib/${serviceName}";
  daemonHomeDir =
    if cfg.homeDir != null
    then cfg.homeDir
    else stateDir;
  daemonCfg =
    cfg
    // {
      homeDir = daemonHomeDir;
    };
in {
  options = lib.recursiveUpdate bwrapModule.mkOptions {
    services.harness-jail.homeDir = {
      default = null;
      defaultText = lib.literalExpression "null";
    };
  };

  config = lib.mkMerge [
    (bwrapModule.mkConfigFor config cfg ({bwrapCommand, ...}: {
      environment.systemPackages = [
        pkgs.bubblewrap
        (pkgs.writeShellScriptBin cfg.wrapperName ''
          exec ${bwrapCommand} "$@"
        '')
      ];
    }))

    (lib.mkIf cfg.daemon (bwrapModule.mkConfigFor config daemonCfg ({bwrapCommand, ...}: let
      sandboxedHarness = pkgs.writeShellScript "${serviceName}-sandboxed" ''
        exec ${bwrapCommand}
      '';
    in {
      users.users.${serviceName} = {
        isSystemUser = true;
        group = serviceName;
        description = "User running the sandboxed LLM harness";
        home = daemonHomeDir;
        createHome = true;
      };

      users.groups.${serviceName} = {};

      systemd.services.${serviceName} = {
        description = "LLM harness sandboxed via Bubblewrap";
        after = ["network.target"];
        wantedBy = ["multi-user.target"];

        serviceConfig = {
          ExecStart = "${sandboxedHarness}";
          User = serviceName;
          Group = serviceName;
          StateDirectory = serviceName;
          WorkingDirectory = daemonHomeDir;
          Restart = "on-failure";
          RestartSec = "5s";
        };
      };
    })))
  ];
}
