{ config, lib, pkgs, ... }:

let
  bwrapModule = import ./lib.nix { inherit lib pkgs; };
in
{
  options = bwrapModule.mkOptions;

  config = bwrapModule.mkConfig config ({ bwrapCommand, ... }: {
    packages = [ pkgs.bubblewrap ];

    processes.llm-harness.exec = bwrapCommand;
  });
}
