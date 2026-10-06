{
  inputs,
  pkgs,
  ...
}: {
  overlays = [
    inputs.harness-flake.overlays.default
  ];
  packages = with pkgs; [
    copilot
  ];
  services.harness-jail = {
    enable = true;
    package = pkgs.copilot;
    command = "copilot";
    enableNetwork = true;
    args = [
      "--yolo"
      "--secret-env-vars"
      "COPILOT_GITHUB_TOKEN"
    ];
    clearEnv = true;
    environmentFile = "./.secrets/harness-flake/default/environment_file";
    readWritePaths = [../../.];
    homeDir = "/tmp";
  };
}
