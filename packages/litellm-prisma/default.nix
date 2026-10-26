{
  lib,
  symlinkJoin,
  litellm,
  python3,
  python3Packages,
  prisma-engines_6,
  prisma_6,
  nodejs,
}: let
  python = python3;
  pythonPackages = python3Packages;
  litellmBase = litellm;
  prismaEngines = prisma-engines_6;
  prismaCli = prisma_6;
  litellmProxyExtrasSource = "${litellmBase.src}/litellm-proxy-extras";
  litellmProxyExtrasVersion =
    (builtins.fromTOML (builtins.readFile "${litellmProxyExtrasSource}/pyproject.toml")).project.version;

  litellmProxyExtras = pythonPackages.buildPythonPackage {
    pname = "litellm-proxy-extras";
    version = litellmProxyExtrasVersion;
    src = litellmProxyExtrasSource;
    pyproject = true;
    build-system = [pythonPackages."uv-build"];
    postPatch = ''
      rm -rf dist
      substituteInPlace pyproject.toml \
        --replace-fail "uv_build==0.11.8" "uv_build==${pythonPackages."uv-build".version}"
    '';
    pythonImportsCheck = ["litellm_proxy_extras"];
    doCheck = false;
  };

  prismaWithClient = pythonPackages.prisma.overridePythonAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [nodejs];
    postInstall =
      (old.postInstall or "")
      + ''
        # Without recursive_type_depth = -1 the client's types.py reaches ~600k lines
        # and takes minutes to import, which stalls litellm startup silently.
        sed -e '/recursive_type_depth/d' \
            -e 's/^\(\s*provider\s*=\s*"prisma-client-py"\)/\1\n  recursive_type_depth = -1/' \
            "${litellmBase.src}/litellm/proxy/schema.prisma" > "$TMPDIR/schema.prisma"
        grep -q 'recursive_type_depth = -1' "$TMPDIR/schema.prisma"

        prismaCache="$TMPDIR/prisma-python-cache"
        mkdir -p "$prismaCache/node_modules/prisma/build"
        ln -s "${prismaCli}/lib/prisma/packages/cli/build/index.js" \
          "$prismaCache/node_modules/prisma/build/index.js"

        PRISMA_BINARY_CACHE_DIR="$prismaCache" \
        PRISMA_VERSION="${prismaCli.version}" \
        PRISMA_PY_DEBUG_GENERATOR=true \
        PRISMA_QUERY_ENGINE_BINARY="${prismaEngines}/bin/query-engine" \
        PRISMA_SCHEMA_ENGINE_BINARY="${prismaEngines}/bin/schema-engine" \
        PATH="$out/bin:${nodejs}/bin:$PATH" \
        PYTHONPATH="$out/${python.sitePackages}:''${PYTHONPATH:-}" \
          ${python.interpreter} -m prisma generate \
            --schema "$TMPDIR/schema.prisma"

        test -f "$out/${python.sitePackages}/prisma/client.py"
      '';
  });
in
  symlinkJoin {
    name = "litellm-prisma-${litellmBase.version}";
    paths = [litellmProxyExtras prismaWithClient];
    meta = {
      description = "LiteLLM with a pre-generated Prisma client for Nix";
      homepage = "https://github.com/BerriAI/litellm";
      license = lib.licenses.mit;
      maintainers = [
        {
          name = "Sylvain Carisey";
          email = "sylvain@carisey.dev";
          github = "scarisey";
        }
      ];
      platforms = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
    };
    passthru = {
      inherit litellmProxyExtras prismaWithClient;
      # Subprocesses (prisma CLI) run a bare interpreter, so they need the whole closure on PYTHONPATH.
      pythonPath = pythonPackages.makePythonPath (
        pythonPackages.requiredPythonModules [litellmProxyExtras prismaWithClient]
      );
    };
  }
