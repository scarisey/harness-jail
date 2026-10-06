{
  inputs,
  pkgs,
  ...
}: {
  overlays = [
    inputs.opencode.overlays.default
  ];
  packages = with pkgs; [
    opencode
  ];
  services.harness-jail = {
    enable = true;
    package = pkgs.opencode;
    command = "opencode";
    enableNetwork = true;
    args = ["--standalone"];
    clearEnv = true;
    homeDir = /tmp/home;
    readWritePaths = [
      ../../.
    ];
  };
}
