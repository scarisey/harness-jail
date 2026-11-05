{
  pkgs,
  lib,
  python3,
  uv2nix,
  pyproject-nix,
  pyproject-build-systems,
}: let
  python = python3;

  workspace = uv2nix.lib.workspace.loadWorkspace {workspaceRoot = ./.;};

  lockOverlay = workspace.mkPyprojectOverlay {
    sourcePreference = "wheel";
  };

  # uv2nix can only use the metadata present in uv.lock. Add fixups here if a
  # wheel needs extra native libraries or a package has to be built from source.
  pyprojectOverrides = final: prev: {
    # LiteLLM generates the Prisma client at build time so the proxy can run
    # database-backed features without downloading engines or a Node toolchain
    # at runtime. The schema ships in the LiteLLM wheel.
    prisma = prev.prisma.overrideAttrs (old: {
      nativeBuildInputs = (old.nativeBuildInputs or []) ++ [pkgs.nodejs];

      postInstall =
        (old.postInstall or "")
        + ''
          # Without recursive_type_depth = -1 the client's types.py reaches
          # ~600k lines and takes minutes to import, which stalls litellm
          # startup silently.
          sed -e '/recursive_type_depth/d' \
              -e 's/^\(\s*provider\s*=\s*"prisma-client-py"\)/\1\n  recursive_type_depth = -1/' \
              "${final.litellm}/${python.sitePackages}/litellm/proxy/schema.prisma" > "$TMPDIR/schema.prisma"
          grep -q 'recursive_type_depth = -1' "$TMPDIR/schema.prisma"

          prismaCache="$TMPDIR/prisma-python-cache"
          mkdir -p "$prismaCache/node_modules/prisma/build"
          ln -s "${pkgs.prisma_6}/lib/prisma/packages/cli/build/index.js" \
            "$prismaCache/node_modules/prisma/build/index.js"

          PRISMA_BINARY_CACHE_DIR="$prismaCache" \
          PRISMA_VERSION="${pkgs.prisma_6.version}" \
          PRISMA_PY_DEBUG_GENERATOR=true \
          PRISMA_QUERY_ENGINE_BINARY="${pkgs.prisma-engines_6}/bin/query-engine" \
          PRISMA_SCHEMA_ENGINE_BINARY="${pkgs.prisma-engines_6}/bin/schema-engine" \
          PATH="$out/bin:${pkgs.nodejs}/bin:$PATH" \
          PYTHONPATH="$out/${python.sitePackages}:${prismaDepsEnv}/${python.sitePackages}:''${PYTHONPATH:-}" \
            ${python.interpreter} -m prisma generate \
              --schema "$TMPDIR/schema.prisma"

          test -f "$out/${python.sitePackages}/prisma/client.py"

          # The generated client records the temporary build schema path.
          # Point it at the schema shipped with LiteLLM instead.
          grep -rl "SCHEMA_PATH = Path('/build/schema.prisma')" \
            "$out/${python.sitePackages}/prisma" 2>/dev/null | while IFS= read -r file; do
            substituteInPlace "$file" \
              --replace-fail \
              "SCHEMA_PATH = Path('/build/schema.prisma')" \
              "SCHEMA_PATH = Path('${final.litellm}/${python.sitePackages}/litellm/proxy/schema.prisma')"
          done
        '';
    });
  };

  basePythonSet =
    (pkgs.callPackage pyproject-nix.build.packages {
      inherit python;
    })
  .overrideScope
    (lib.composeManyExtensions [
      pyproject-build-systems.overlays.wheel
      lockOverlay
    ]);

  # pyproject.nix does not put a package's dependencies on PYTHONPATH for
  # postInstall, so build the unpatched Prisma environment and borrow its
  # site-packages while generating the client.
  prismaDepsEnv = basePythonSet.mkVirtualEnv "prisma-build-deps" {prisma = [];};

  pythonSet = basePythonSet.overrideScope pyprojectOverrides;

  venv = pythonSet.mkVirtualEnv "litellm-env" {
    litellm = [
      "proxy"
      "extra-proxy"
      "proxy-runtime"
    ];
  };

  version = pythonSet.litellm.version;

  package = venv.overrideAttrs (old: {
    name = "litellm-${version}";

    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [pkgs.makeWrapper];

    # soundfile dlopen()s libsndfile at runtime instead of linking it.
    postInstall =
      (old.postInstall or "")
      + ''
        for bin in litellm litellm-proxy lite; do
          wrapProgram "$out/bin/$bin" \
            --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [pkgs.libsndfile]}
        done

        LD_LIBRARY_PATH="${lib.makeLibraryPath [pkgs.libsndfile]}" \
        SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" \
        REQUESTS_CA_BUNDLE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" \
        CURL_CA_BUNDLE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" \
        PYTHONPATH="$out/${python.sitePackages}" \
          ${python.interpreter} -c "import litellm.proxy.proxy_server"
      '';

    meta = {
      description = "LiteLLM proxy with the full server dependency set";
      homepage = "https://github.com/BerriAI/litellm";
      license = lib.licenses.mit;
      mainProgram = "litellm";
      maintainers = [
        {
          name = "Sylvain Carisey";
          email = "sylvain@carisey.dev";
          github = "scarisey";
        }
      ];
      platforms = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    };

    passthru =
      (old.passthru or {})
      // {
        inherit python pythonSet venv version;
        pythonPath = "${package}/${python.sitePackages}";
        prisma = pkgs.prisma_6;
        prismaEngines = pkgs.prisma-engines_6;
        isLiteLLMProxy = true;
      };
  });
in
  package
