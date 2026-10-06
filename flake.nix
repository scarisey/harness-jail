{
  description = "Harness nix module. For NixOS / Home manager / Devenv.";

  inputs = {};

  outputs = {self,...}:
    {
      nixosModules.llm-harness = ./modules/nixos.nix;
      nixosModules.default = self.nixosModules.llm-harness;

      homeManagerModules.llm-harness = ./modules/home-manager.nix;
      homeManagerModules.default = self.homeManagerModules.llm-harness;

      devenvModules.llm-harness = ./modules/devenv.nix;
      devenvModules.default = self.devenvModules.llm-harness;
    };
}
