{
  stdenv,
  fetchurl,
  autoPatchelfHook,
  lib,
}: let
  versions = builtins.fromJSON (builtins.readFile ./versions.json);
  pname = "github-copilot-cli";
  inherit (versions) version;

  platformMap = {
    "x86_64-linux" = {
      pkgName = "copilot-linux-x64";
      sha256 = versions.sha256Linux_x64;
    };
    "aarch64-linux" = {
      pkgName = "copilot-linux-arm64";
      sha256 = versions.sha256Linux_arm64;
    };
    "aarch64-darwin" = {
      pkgName = "copilot-darwin-arm64";
      sha256 = versions.sha256Darwin_arm64;
    };
  };

  platform = platformMap.${stdenv.hostPlatform.system};
in
  stdenv.mkDerivation rec {
    inherit pname version;

    src = fetchurl {
      url = "https://registry.npmjs.org/@github/${platform.pkgName}/-/${platform.pkgName}-${version}.tgz";
      inherit (platform) sha256;
    };

    nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];
    buildInputs = lib.optionals stdenv.hostPlatform.isLinux [stdenv.cc.cc.lib];

    dontBuild = true;
    dontStrip = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin $out/share/licenses/${pname}
      cp copilot $out/bin/copilot
      cp LICENSE.md $out/share/licenses/${pname}/LICENSE.md
      chmod +x $out/bin/copilot
      runHook postInstall
    '';

    meta = {
      description = "GitHub Copilot CLI";
      homepage = "https://github.com/github/copilot-cli";
      license = lib.licenses.unfreeRedistributable;
      mainProgram = "copilot";
      maintainers = [
        {
          name = "Sylvain Carisey";
          email = "sylvain@carisey.dev";
          github = "scarisey";
        }
      ];
      platforms = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
    };
  }
