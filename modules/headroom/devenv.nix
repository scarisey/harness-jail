{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.services.headroom;
  headroomLib = import ./lib.nix {inherit pkgs lib;};
  stateDir = "$DEVENV_STATE/headroom";

  sandboxedHeadroom = headroomLib.buildScript {
    inherit cfg stateDir;
  };
in {
  options.services.headroom = headroomLib.mkOptions;

  config = lib.mkIf cfg.enable {
    packages = [
      cfg.package
      pkgs.bubblewrap
    ];

    processes.headroom = {
      exec = "${sandboxedHeadroom}/bin/headroom-proxy";
    };
  };
}
