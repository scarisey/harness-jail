# Shared harness-jail module implementation.
# Public API: mkOptions, mkConfigFor, mkConfig.
{
  lib,
  pkgs,
}: let
  inherit (lib) mkIf optional;

  mkOptions = import ./options.nix {inherit lib pkgs;};
  sandbox = import ./sandbox.nix {inherit lib pkgs;};

  # `render` receives { cfg, bwrapCommand } and must return a NixOS, Home
  # Manager, or devenv configuration. It only runs when cfg.enable is true.
  mkConfigFor = hostConfig: cfg: render: let
    extraReadWritePaths =
      optional (hostConfig ? devenv) hostConfig.devenv.root;

    bwrapCommand = sandbox.mkBwrapCommand {
      inherit cfg extraReadWritePaths;
    };
  in
    mkIf cfg.enable (render {inherit cfg bwrapCommand;});
in {
  inherit mkOptions mkConfigFor;

  mkConfig = config: render:
    mkConfigFor config config.services.harness-jail render;
}
