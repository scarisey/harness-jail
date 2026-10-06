{ config, lib, pkgs, ... }:

let
  bwrapModule = import ./lib.nix { inherit lib pkgs; };
in
{
  options = bwrapModule.mkOptions;

  config = bwrapModule.mkConfig config ({ bwrapCommand, ... }: {
    home.packages = [ pkgs.bubblewrap ];

    systemd.user.services.llm-harness = {
      Unit = {
        Description = "LLM Secure Harness Service (Home Manager)";
        After = [ "network.target" ];
      };

      Service = {
        Type = "simple";
        ExecStart = bwrapCommand;
        Restart = "on-failure";
        NoNewPrivileges = true;
      };

      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  });
}
