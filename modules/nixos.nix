{ config, lib, pkgs, ... }:

let
  bwrapModule = import ./lib.nix { inherit lib pkgs; };
in
{
  options = bwrapModule.mkOptions;

  config = bwrapModule.mkConfig config ({ bwrapCommand, ... }: {
    environment.systemPackages = [ pkgs.bubblewrap ];

    systemd.services.llm-harness = {
      description = "LLM Secure Harness Service (NixOS)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = bwrapCommand;
        Restart = "on-failure";
        
        NoNewPrivileges = true;
        ProtectSystem = "strict";
      };
    };
  });
}
