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
in {
  options = lib.recursiveUpdate bwrapModule.mkOptions {
    services.harness-jail.homeDir = {
      default = stateDir;
      defaultText = lib.literalExpression ''"/var/lib/harness-jail"'';
    };
  };

  config = bwrapModule.mkConfig config ({bwrapCommand, ...}: let
    sandboxedHarness = pkgs.writeShellScript "${serviceName}-sandboxed" ''
      exec ${bwrapCommand}
    '';
  in {
    users.users.${serviceName} = {
      isSystemUser = true;
      group = serviceName;
      description = "User running the sandboxed LLM harness";
      home = stateDir;
      createHome = true;
    };

    users.groups.${serviceName} = {};

    systemd.services.${serviceName} = lib.mkIf cfg.daemon {
      description = "LLM harness sandboxed via Bubblewrap";
      after = ["network.target"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        ExecStart = "${sandboxedHarness}";
        User = serviceName;
        Group = serviceName;
        StateDirectory = serviceName;
        WorkingDirectory = stateDir;
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    environment.systemPackages = [
      pkgs.bubblewrap
      (pkgs.writeShellScriptBin cfg.wrapperName ''
        exec ${bwrapCommand} "$@"
      '')
    ];
  });
}
