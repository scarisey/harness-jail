{
  stdenv,
  fetchurl,
  patchelf,
  makeWrapper,
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
  isLinux = stdenv.hostPlatform.isLinux;
in
  stdenv.mkDerivation rec {
    inherit pname version;

    src = fetchurl {
      url = "https://registry.npmjs.org/@github/${platform.pkgName}/-/${platform.pkgName}-${version}.tgz";
      inherit (platform) sha256;
    };

    dontAutoPatchelf = true;

    nativeBuildInputs = lib.optionals isLinux [patchelf makeWrapper];
    buildInputs = lib.optionals isLinux [stdenv.cc.cc.lib];

    dontBuild = true;
    dontStrip = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin

      ${lib.optionalString isLinux ''
        mkdir -p $out/libexec
        install -m755 copilot $out/libexec/copilot

        # Only set the interpreter: adding an RPATH breaks the SEA layout (see
        # the comment above dontAutoPatchelf).
        patchelf --set-interpreter ${stdenv.cc.bintools.dynamicLinker} $out/libexec/copilot

        makeWrapper $out/libexec/copilot $out/bin/copilot \
          --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [stdenv.cc.cc.lib]}
      ''}

      ${lib.optionalString (!isLinux) ''
        install -m755 copilot $out/bin/copilot
      ''}

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
