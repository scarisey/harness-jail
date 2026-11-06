{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.services.litellm;
  litellmLib = import ./lib.nix {inherit pkgs lib;};

  sandboxedLiteLLM = litellmLib.buildScript {
    inherit cfg;
    stateDir = "${config.home.homeDirectory}/.local/share/litellm";
  };
in {
  options.services.litellm = litellmLib.mkOptions;

  config = lib.mkIf cfg.enable {
    home.packages = [
      cfg.package
      pkgs.bubblewrap
    ];

    systemd.user.services.litellm = {
      Unit = {
        Description = "LiteLLM user proxy (sandboxed via Bubblewrap)";
        After = ["network.target"];
      };

      Install = {
        WantedBy = ["default.target"];
      };

      Service = {
        ExecStart = "${sandboxedLiteLLM}/bin/litellm-sandboxed";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
