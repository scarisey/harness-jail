{
  description = ''
    Harness jail modules. For NixOS / Home manager / Devenv.
    Opinionated way to run a harness on Nix, with utilities.
  '';

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
    };
  };

  outputs = {
    self,
    nixpkgs,
    home-manager,
    pyproject-nix,
    uv2nix,
    pyproject-build-systems,
    ...
  }: let
    supportedSystems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
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
          pkgs.curl
          pkgs.jq
          pkgs.nix
          pkgs.nodejs_latest
          pkgs.python3
          pkgs.uv
        ];
        shellHook = ''
          echo "Launch update commands here."
          find . -name 'update.sh' -print
        '';
        NIX_SHELL_PRESERVE_ENVIRONMENT = ["HOME"];
      };
    });

    packages = forAllSystems ({pkgs, ...}:
      {
        copilot = pkgs.callPackage ./packages/copilot {};
        headroom = pkgs.callPackage ./packages/headroom {};
      }
      // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        litellm = pkgs.callPackage ./packages/litellm {
          inherit uv2nix pyproject-nix pyproject-build-systems;
        };
      });

    checks = forAllSystems ({pkgs, ...}: let
      networkFilter = import ./modules/harness/network-filter.nix {
        inherit (pkgs) lib pkgs;
      };
      filterFile =
        (networkFilter.mk {
          cfg = {
            enableNetwork = true;
            networkFilter.patterns = [
              "example.com"
              "*.example.com"
              "q?.example.com"
              "[ab]c.example.com"
              "[!ab]c.example.com"
            ];
          };
        })
        .filterFile;
      expectedFilter = pkgs.writeText "harness-jail-network-filter-expected" ''
        example.com
        *.example.com
        q?.example.com
        [ab]c.example.com
        [!ab]c.example.com
      '';
    in
      nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        harness-network-filter-glob = pkgs.runCommand "harness-network-filter-glob" {} ''
          diff -u ${expectedFilter} ${filterFile}
          touch $out
        '';
        nixos-harness-network-filter = pkgs.callPackage ./example/nixos-harness-network-filter {inherit self;};
        nixos-harness-one-shot = pkgs.callPackage ./example/nixos-harness-one-shot {inherit self;};
        nixos-headroom = pkgs.callPackage ./example/nixos-headroom {inherit self;};
        nixos-opencode-litellm = pkgs.callPackage ./example/nixos-opencode-litellm {inherit self;};
        home-manager-opencode-litellm = pkgs.callPackage ./example/home-manager-opencode-litellm {
          inherit self home-manager;
        };
      });

    overlays.default = final: prev:
      nixpkgs.lib.optionalAttrs (builtins.elem prev.stdenv.hostPlatform.system supportedSystems) {
        copilot = final.callPackage ./packages/copilot {};
        headroom = final.callPackage ./packages/headroom {};
      }
      // nixpkgs.lib.optionalAttrs (prev.stdenv.hostPlatform.isLinux
        && builtins.elem prev.stdenv.hostPlatform.system supportedSystems) {
        litellm = final.callPackage ./packages/litellm {
          inherit uv2nix pyproject-nix pyproject-build-systems;
        };
      };

    nixosModules = {
      harness-jail = ./modules/harness/nixos.nix;
      headroom = ./modules/headroom/nixos.nix;
      litellm = ./modules/litellm/nixos.nix;
    };

    homeManagerModules = {
      harness-jail = ./modules/harness/home-manager.nix;
      headroom = ./modules/headroom/home-manager.nix;
      litellm = ./modules/litellm/home-manager.nix;
    };

    devenvModules = {
      harness-jail = ./modules/harness/devenv.nix;
      headroom = ./modules/headroom/devenv.nix;
      litellm = ./modules/litellm/devenv.nix;
    };

    formatter = forAllSystems ({pkgs, ...}: pkgs.alejandra);
  };
  nixConfig = {
    extra-substituters = [
      "https://nix-community.cachix.org?priority=31"
      "https://scarisey-public.cachix.org?priority=32"
    ];
    extra-trusted-public-keys = [
      "scarisey-public.cachix.org-1:kabqlCM0Wwd3iOh+C62WQg7vUO7vX3JbKKraSmxr2n8="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };
}
