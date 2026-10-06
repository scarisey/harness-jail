{
  description = ''
    Harness jail modules. For NixOS / Home manager / Devenv.
    Opiniated way to run a harness on Nix, with utilities.
  '';

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    home-manager,
    ...
  }: let
    supportedSystems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    forAllSystems = f:
      nixpkgs.lib.genAttrs supportedSystems (system:
        f {
          inherit system;
          pkgs = import nixpkgs {inherit system;};
        });
  in {
    devShells = forAllSystems ({pkgs, ...}: {
      updateShell = pkgs.mkShell {
        packages = [
          pkgs.nodejs_latest
          pkgs.jq
        ];
        shellHook = ''
          echo "Launch update commands here."
          find . -name 'update.sh' -print
        '';
        NIX_SHELL_PRESERVE_ENVIRONMENT = ["HOME"];
      };
    });

    packages = forAllSystems ({pkgs, ...}: {
      copilot = pkgs.callPackage ./packages/copilot {};
      headroom = pkgs.callPackage ./packages/headroom {};
      litellm-prisma = pkgs.callPackage ./packages/litellm-prisma {};
    });

    checks = forAllSystems ({pkgs, ...}:
      nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        nixos-harness-one-shot = pkgs.callPackage ./example/nixos-harness-one-shot {inherit self;};
        nixos-headroom = pkgs.callPackage ./example/nixos-headroom {inherit self;};
        nixos-opencode-litellm = pkgs.callPackage ./example/nixos-opencode-litellm {inherit self;};
        home-manager-opencode-litellm = pkgs.callPackage ./example/home-manager-opencode-litellm {
          inherit self home-manager;
        };
      });

    overlays.default = final: prev: {
      copilot = self.packages.${final.stdenv.hostPlatform.system}.copilot;
      headroom = self.packages.${final.stdenv.hostPlatform.system}.headroom;
    };

    nixosModules.harness-jail = ./modules/harness/nixos.nix;
    nixosModules.headroom = ./modules/headroom/nixos.nix;
    nixosModules.litellm = ./modules/litellm/nixos.nix;

    homeManagerModules.harness-jail = ./modules/harness/home-manager.nix;
    homeManagerModules.headroom = ./modules/headroom/home-manager.nix;
    homeManagerModules.litellm = ./modules/litellm/home-manager.nix;

    devenvModules.harness-jail = ./modules/harness/devenv.nix;
    devenvModules.headroom = ./modules/headroom/devenv.nix;
    devenvModules.litellm = ./modules/litellm/devenv.nix;
    formatter = forAllSystems ({pkgs, ...}: pkgs.alejandra);
  };
}
