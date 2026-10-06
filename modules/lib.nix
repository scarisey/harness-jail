{ lib, pkgs }:

with lib;

let
  mkOptions = {
    services.bwrapHarness = {
      enable = mkEnableOption "Activate LLM harness asndboxing.";

      package = mkOption {
        type = types.str;
        description = "Path to executable";
      };

      args = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Arguments passed to exectuable.";
      };

      enableNetwork = mkOption {
        type = types.bool;
        default = false;
        description = "Enable network access.";
      };

      readOnlyPaths = mkOption {
        type = types.listOf types.path;
        default = [];
        description = "Path that would be read by harness.";
      };

      readWritePaths = mkOption {
        type = types.listOf types.path;
        default = [];
        description = "Path that would read/written by harness.";
      };

      clearEnv = mkOption {
        type = types.bool;
        default = true;
        description = "Don't heritate from host environment variables.";
      };

      environment = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Specific environment variables.";
      };
    };
  };

  # f : { cfg, bwrapCommand } -> nixConfig
  mkConfig = config: f:
    let
      cfg = config.services.bwrapHarness;

      bwrapArgs = [
        "--unshare-all"
        "--die-with-parent"
        "--dev /dev"
        "--proc /proc"
        "--tmpfs /tmp"
        "--ro-bind /nix /nix"
        "--ro-bind /etc/resolv.conf /etc/resolv.conf"
      ]
      ++ optional cfg.clearEnv "--clearenv"
      ++ concatLists (mapAttrsToList (name: value: [ "--setenv" name value ]) cfg.environment)
      ++ map (path: "--ro-bind ${path} ${path}") cfg.readOnlyPaths
      ++ map (path: "--bind ${path} ${path}") cfg.readWritePaths
      ++ optional (!cfg.enableNetwork) "--unshare-net"
      ++ [ "--" ] ++ [ cfg.package ] ++ cfg.args;

      bwrapCommand = "${pkgs.bubblewrap}/bin/bwrap " + concatStringsSep " " bwrapArgs;
    in
    mkIf cfg.enable (f { inherit cfg bwrapCommand; });

in
{
  inherit mkOptions mkConfig;
}
