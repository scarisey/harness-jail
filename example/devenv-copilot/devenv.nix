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
    # SecretSpec stores this under ~/.config/harness-jail, outside the project
    # root and outside every path mounted into the sandbox.
    environmentFile = "${builtins.getEnv "HOME"}/.config/harness-jail/secrets/harness-flake/default/environment_file";
    homeDir = ./.home;
  };
}
