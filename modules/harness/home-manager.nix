{
  config,
  lib,
  pkgs,
  ...
}: let
  bwrapModule = import ./lib.nix {inherit lib pkgs;};
  cfg = config.services.harness-jail;
  serviceName = "harness-jail";
  stateDir = "${config.home.homeDirectory}/.local/state/${serviceName}";
in {
  options = lib.recursiveUpdate bwrapModule.mkOptions {
    services.harness-jail.homeDir = {
      default = stateDir;
      defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/.local/state/harness-jail"'';
    };
  };

  config = bwrapModule.mkConfig config ({bwrapCommand, ...}: let
    sandboxedHarness = pkgs.writeShellScript "${serviceName}-sandboxed" ''
      exec ${bwrapCommand}
    '';
  in {
    home.activation.createHarnessJailState = lib.hm.dag.entryAfter ["writeBoundary"] ''
      run mkdir -p $VERBOSE_ARG ${lib.escapeShellArg (toString cfg.homeDir)}
    '';

    systemd.user.services.${serviceName} = lib.mkIf cfg.daemon {
      Unit = {
        Description = "LLM harness sandboxed via Bubblewrap";
        After = ["network.target"];
      };

      Service = {
        ExecStart = "${sandboxedHarness}";
        WorkingDirectory = cfg.homeDir;
        Restart = "on-failure";
        RestartSec = "5s";
      };

      Install.WantedBy = ["default.target"];
    };

    home.packages = [
      pkgs.bubblewrap
      (pkgs.writeShellScriptBin cfg.wrapperName ''
        exec ${bwrapCommand} "$@"
      '')
    ];
  });
}
