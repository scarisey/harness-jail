{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.services.headroom;
  headroomLib = import ./lib.nix {inherit pkgs lib;};
  stateDir = "/var/lib/headroom";

  sandboxedHeadroom = headroomLib.buildScript {
    inherit cfg stateDir;
  };
in {
  options.services.headroom = headroomLib.mkOptions;

  config = lib.mkIf cfg.enable {
    users.users.headroom = {
      isSystemUser = true;
      group = "headroom";
      description = "User running the Headroom proxy";
      home = stateDir;
      createHome = true;
    };

    users.groups.headroom = {};

    systemd.services.headroom = {
      description = "Headroom optimization proxy (sandboxed via Bubblewrap)";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        ExecStart = "${sandboxedHeadroom}/bin/headroom-proxy";
        User = "headroom";
        Group = "headroom";
        StateDirectory = "headroom";
        WorkingDirectory = stateDir;
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    environment.systemPackages = [
      cfg.package
      pkgs.bubblewrap
    ];
  };
}
