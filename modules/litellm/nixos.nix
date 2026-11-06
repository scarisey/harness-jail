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
    stateDir = "/var/lib/litellm";
  };
in {
  options.services.litellm = litellmLib.mkOptions;

  config = lib.mkIf cfg.enable {
    users.users.litellm = {
      isSystemUser = true;
      group = "litellm";
      description = "User for the LiteLLM daemon";
      home = "/var/lib/litellm";
      createHome = true;
    };

    users.groups.litellm = {};

    systemd.services.litellm = {
      description = "Proxy LiteLLM (sandboxed via Bubblewrap)";
      after = ["network.target"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        ExecStart = "${sandboxedLiteLLM}/bin/litellm-sandboxed";
        User = "litellm";
        Group = "litellm";
        StateDirectory = "litellm";
        WorkingDirectory = "/var/lib/litellm";
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
