{
  lib,
  stdenv,
  fetchurl,
  python3,
  ast-grep,
}:
let
  versions = builtins.fromJSON (builtins.readFile ./headroom-versions.json);
  platformMap = {
    "x86_64-linux" = {
      url = versions.urlLinux_x64;
      hash = versions.sha256Linux_x64;
    };
    "aarch64-linux" = {
      url = versions.urlLinux_arm64;
      hash = versions.sha256Linux_arm64;
    };
    "x86_64-darwin" = {
      url = versions.urlDarwin_x64;
      hash = versions.sha256Darwin_x64;
    };
    "aarch64-darwin" = {
      url = versions.urlDarwin_arm64;
      hash = versions.sha256Darwin_arm64;
    };
  };
  platform = platformMap.${stdenv.hostPlatform.system};
  propagatedBuildInputs = with python3.pkgs; [
    tiktoken
    pydantic
    litellm
    click
    rich
    opentelemetry-api
    pyyaml
    tomli
    tomlkit
    fastapi
    uvicorn
    orjson
    httpx
    h2
    openai
    mcp
    magika
    zstandard
    websockets
    onnxruntime
    transformers
    watchdog
    sqlite-vec
  ];
in
python3.pkgs.buildPythonApplication {
  pname = "headroom-ai";
  inherit (versions) version;
  format = "wheel";

  src = fetchurl {
    inherit (platform) url hash;
  };

  # ast-grep-cli only provides a binary, not an importable Python module.
  dontCheckRuntimeDeps = true;

  inherit propagatedBuildInputs;

  # `headroom wrap` spawns `python -m headroom.cli` in a subprocess, which
  # needs its own PYTHONPATH in addition to the entry point's site.addsitedir.
  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    "${lib.makeBinPath [ ast-grep ]}"
    "--prefix"
    "PYTHONPATH"
    ":"
    "$out/${python3.sitePackages}:${python3.pkgs.makePythonPath propagatedBuildInputs}"
  ];

  pythonImportsCheck = [ "headroom" ];

  meta = {
    description = "Compresses tool outputs and LLM context through a local proxy";
    homepage = "https://github.com/headroomlabs-ai/headroom";
    changelog = "https://github.com/headroomlabs-ai/headroom/blob/main/CHANGELOG.md";
    license = lib.licenses.asl20;
    mainProgram = "headroom";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];
  };
}
