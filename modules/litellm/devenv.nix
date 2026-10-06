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
    stateDir = "$DEVENV_STATE/litellm";
  };
in {
  options.services.litellm = litellmLib.mkOptions;

  config = lib.mkIf cfg.enable {
    packages = [
      cfg.package
      pkgs.bubblewrap
    ];

    processes.litellm = {
      exec = "${sandboxedLiteLLM}/bin/litellm-sandboxed";
    };
  };
}
