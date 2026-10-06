{
  config,
  lib,
  pkgs,
  ...
}: let
  bwrapModule = import ./lib.nix {inherit lib pkgs;};
  cfg = config.services.harness-jail;
in {
  options = bwrapModule.mkOptions;

  config = bwrapModule.mkConfig config ({bwrapCommand, ...}: {
    packages = [pkgs.bubblewrap];

    scripts.${cfg.wrapperName}.exec = ''exec ${bwrapCommand} "$@"'';
  });
}
