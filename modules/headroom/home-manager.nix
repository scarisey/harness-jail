{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.services.headroom;
  headroomLib = import ./lib.nix {inherit pkgs lib;};
  stateDir = "${config.home.homeDirectory}/.local/share/headroom";

  sandboxedHeadroom = headroomLib.buildScript {
    inherit cfg stateDir;
  };
in {
  options.services.headroom = headroomLib.mkOptions;

  config = lib.mkIf cfg.enable {
    home.packages = [
      cfg.package
      pkgs.bubblewrap
    ];

    systemd.user.services.headroom = {
      Unit = {
        Description = "Headroom optimization proxy (sandboxed via Bubblewrap)";
        After = ["network.target"];
      };

      Install = {
        WantedBy = ["default.target"];
      };

      Service = {
        ExecStart = "${sandboxedHeadroom}/bin/headroom-proxy";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
