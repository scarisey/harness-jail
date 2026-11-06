# harness-jail project review

Reviewed the flake, NixOS/Home Manager/devenv modules, packages, examples, CI
workflows, README, and update scripts. No project files were changed during the
review except for the creation of this document.

## Verification performed

- `nix flake check --impure --no-build` passes with `NIXPKGS_ALLOW_UNFREE=1`,
  `NIXPKGS_ALLOW_BROKEN=1`, and `NIXPKGS_ALLOW_INSECURE=1`.
- `nix run .#litellm -- --version` reports LiteLLM `1.108.0`.
- The four NixOS VM tests were not run during this review, so runtime findings
  below are code-level unless stated otherwise.

Overall the project is well structured and the LiteLLM packaging is unusually
thorough. The main risks are not in the core sandbox plumbing; they are in
example security, the NixOS wrapper/service split, stale devenv locks, overlay
portability, and CI duplication.

## High priority

### 1. Example setups defeat their own sandbox

This is the most important issue because these examples are what users copy.

- `example/home-manager-opencode-litellm/default.nix:53` sets:

  ```nix
  homeDir = "/home/test";
  ```

  That bind-mounts the entire user home read-write into the sandbox, including
  `~/.ssh`, `~/.config`, credentials, and browser data. It directly contradicts
  the README's "host home directory and its credentials are not visible" claim.
  Use a dedicated directory such as `~/.local/state/harness-jail` or the module
  default.

- `example/devenv-copilot/devenv.nix:23` loads the secret file from
  `.secrets/...`, which lives inside the devenv project root.
  `modules/harness/lib.nix:104` automatically mounts `config.devenv.root`
  read-write, so the agent can read the environment file from inside the
  sandbox. The `--secret-env-vars` flag does not help if the file itself is
  readable. Store the secret outside the project root, or add a masking bind for
  `environmentFile` inside bwrap.

- The same examples also add `readWritePaths = [../../.]`:
  - `example/devenv-copilot/devenv.nix:24`
  - `example/devenv-opencode-litellm/devenv.nix:22-24`
  - `example/devenv-opencode-simple/devenv.nix:20-22`

  In devenv, `config.devenv.root` is already mounted read-write, so these entries
  are redundant and expose the whole harness-jail repository, including `.git`
  and `.secrets`, instead of just the current project.

Recommendations:

- Remove the redundant `readWritePaths = [../../.]` entries.
- Move example secrets outside the project root.
- Change the Home Manager example's `homeDir`.
- Add a warning to the README that `environmentFile` is only hidden if its path
  is not inside `homeDir`, `readWritePaths`, or the devenv root.
- Optionally mask `environmentFile` inside bwrap with a `/dev/null` bind so it
  cannot be read even when it lives under a mounted directory.

### 2. NixOS wrapper and service share an inaccessible home directory

`modules/harness/nixos.nix` installs the `harness` wrapper system-wide, but its
default `homeDir` is `/var/lib/harness-jail`:

- `modules/harness/nixos.nix:13-16` sets the default `homeDir`.
- `modules/harness/nixos.nix:24-32` creates a dedicated `harness-jail` system
  user with `home = /var/lib/harness-jail` and `createHome = true`.
- `modules/harness/nixos.nix:50-55` installs the wrapper for all users.

NixOS user homes default to mode `0700`. A normal user running `harness`
therefore cannot access or bind-mount `/var/lib/harness-jail`; at best the bind
fails, at worst the sandbox starts without a writable home. The existing NixOS
test only invokes `harness` as root
(`example/nixos-harness-one-shot/default.nix:35-41`), so it does not catch this.

Also, when `daemon = false`, `users.users.harness-jail` and
`users.groups.harness-jail` are still created even though no service uses them.

Recommendations:

- Separate the daemon's state directory from the interactive wrapper's home
  directory, or make the wrapper use a per-user writable directory.
- When `daemon = false`, do not create the system user/group unless explicitly
  requested.
- Add a NixOS test that runs `harness` as an unprivileged user.
- Document that the NixOS wrapper is not usable by normal users with the current
  default `homeDir`.

### 3. Example devenv locks are stale

All three example locks predate the new LiteLLM flake inputs:

- `example/devenv-copilot/devenv.lock`
- `example/devenv-opencode-litellm/devenv.lock`
- `example/devenv-opencode-simple/devenv.lock`

Their `harness-flake` nodes only list `nixpkgs` and sometimes `home-manager`;
they do not contain the new `pyproject-nix`, `uv2nix`, or
`pyproject-build-systems` inputs from `flake.nix:13-27`. This is likely to make
`devenv shell` fail or silently resolve an old input graph.

Run `devenv update` in each example and commit the updated `devenv.lock`.

### 4. The overlay is not portable and mixes nixpkgs instances

`flake.nix:83-89`:

```nix
overlays.default = final: prev: {
  copilot = self.packages.${final.stdenv.hostPlatform.system}.copilot;
  headroom = self.packages.${final.stdenv.hostPlatform.system}.headroom;
  litellm = final.callPackage ./packages/litellm { ... };
};
```

I confirmed that applying this overlay on `i686-linux` fails immediately with:

```text
error: attribute 'i686-linux' missing
```

Even on supported systems, `self.packages.${system}` builds Copilot and Headroom
against the flake's pinned nixpkgs rather than the consumer's `final` package
set. That can mix stdenv and library versions with the rest of the user's
system.

Recommendation:

```nix
overlays.default = final: prev: {
  copilot = final.callPackage ./packages/copilot {};
  headroom = final.callPackage ./packages/headroom {};
  litellm = final.callPackage ./packages/litellm { ... };
};
```

If unsupported systems should still evaluate, gate the attribute additions with
`lib.optionalAttrs (builtins.hasAttr system self.packages)` or remove them from
`supportedSystems`.

### 5. CI builds everything twice and does not push from the build workflow

`build.yml:30-37` builds three packages and then runs `nix flake check`, which
includes four NixOS VM tests (`flake.nix:73-81`). `report-and-push.yml:41-43`
then reruns the same `nix flake check` on a fresh runner.

Problems:

- `build.yml` is named "push to cachix" but does not use `cachix-action`; the
  push happens only in `report-and-push.yml`.
- Consequently, every push to `main` builds everything twice, including the four
  VM tests.
- The two LiteLLM/Home Manager tests each request 4 GB of RAM. Depending on
  Nix's `max-jobs` setting, two concurrent VMs can exceed the ~7 GB available on
  a standard `ubuntu-latest` runner. Set `--max-jobs 1` explicitly or split
  checks into a matrix.
- There is no `timeout-minutes` or `concurrency` setting, so a hung VM test can
  run for hours and overlapping pushes can race.

Recommendations:

- Add Cachix push to `build.yml` on trusted pushes, or remove the "push to
  cachix" claim from its name.
- Let `report-and-push` consume the cache instead of rebuilding from scratch.
- Run VM tests with `--max-jobs 1` or one test per matrix job.
- Consider running heavy VM tests only on `main`/nightly, with PRs doing
  `nix flake check --no-build` plus package builds.
- Add `timeout-minutes` and `concurrency`.

Also note that `report-and-push.yml:9-12` only creates the `check_ok` check run
for pushes to `main`. If `check_ok` is a required status check for pull
requests, PRs will never receive it.

### 6. LiteLLM sandbox is missing basic shell compatibility

`modules/litellm/lib.nix:113-184` does not add `/bin/sh` or `/usr/bin/env`,
unlike Harness and Headroom:

- `modules/harness/lib.nix:139-144`
- `modules/headroom/lib.nix:153-158`

LiteLLM itself mostly uses `subprocess` with argument lists, but any dependency
that invokes `shell=True`, `/bin/sh`, or `/usr/bin/env` will fail. This is a
cheap consistency fix:

```nix
"--symlink" "${pkgs.bashNonInteractive}/bin/sh" "/bin/sh"
"--symlink" "${pkgs.coreutils}/bin/env" "/usr/bin/env"
```

While there, consider adding `--cap-drop ALL` to the Headroom and LiteLLM bwrap
argument lists, matching Harness (`modules/harness/lib.nix:145-146`).

### 7. LiteLLM UI path is not configured like the nixpkgs module

The nixpkgs LiteLLM module sets:

```nix
LITELLM_NON_ROOT = "true";
LITELLM_UI_PATH = "${cfg.stateDir}/ui";
```

and creates the UI directory. Our module does not. LiteLLM therefore defaults to
the packaged UI inside the read-only Nix store and may log fallback warnings or
fail to support routes that require a writable/restructured UI.

Recommendation: mirror the nixpkgs behavior:

```nix
"--setenv" "LITELLM_NON_ROOT" "true"
"--setenv" "LITELLM_UI_PATH" "${stateDir}/ui"
```

and `mkdir -p "${stateDir}/ui"` in `modules/litellm/lib.nix` before starting
bwrap.

## Medium priority

### 8. Harness `environmentFile` cannot override default variables

In `modules/harness/lib.nix:149-156`, `clearEnv = true` sets defaults for:

- `HOME`
- `PATH`
- `SSL_CERT_FILE`

In the `environmentFile` path (`modules/harness/lib.nix:180-199`), the file is
sourced first, then `environmentArgs` is appended. Because `environmentArgs`
still contains those defaults, a file value such as `PATH=...` is overridden by
the default.

The README says explicit `environment` values take precedence over the file
(`README.md:225-228`), which is true, but it does not mention that the built-in
defaults also take precedence. A user trying to extend `PATH` from the env file
will be surprised.

Recommendation: either separate default env args from user env args and apply
the file between them, or document that `HOME`, `PATH`, and `SSL_CERT_FILE` are
reserved and cannot be set from `environmentFile`.

### 9. Harness is missing `--new-session`

`modules/headroom/lib.nix:123-128` and `modules/litellm/lib.nix:113-118` use
`--new-session`; `modules/harness/lib.nix:111-147` does not.

Since Harness runs interactive agent CLIs, `--new-session` is useful defense
against terminal injection via `TIOCSTI`. Add it for consistency and defense in
depth.

### 10. NixOS LiteLLM module does not install the package or bubblewrap

`modules/litellm/nixos.nix:18-44` starts the service with absolute paths but
does not add:

```nix
environment.systemPackages = [
  cfg.package
  pkgs.bubblewrap
];
```

Headroom does this at `modules/headroom/nixos.nix:45-48`, and the Home
Manager/devenv LiteLLM modules install the package. As a result, NixOS users do
not get a `litellm` CLI on `PATH`, unlike the other targets.

Either add the `systemPackages` entry or explicitly document that the NixOS
LiteLLM module is service-only. Adding `machine.succeed("litellm --version")`
to `example/nixos-opencode-litellm/default.nix` would catch the inconsistency.

### 11. LiteLLM telemetry is not disabled by default

The nixpkgs LiteLLM module defaults to:

```nix
SCARF_NO_ANALYTICS = "True";
DO_NOT_TRACK = "True";
ANONYMIZED_TELEMETRY = "False";
```

Our `services.litellm.environment` default is `{}`
(`modules/litellm/lib.nix:33-38`). The examples set these manually, but users
who do not copy the examples may send telemetry. Consider making
privacy-preserving defaults part of the module.

### 12. Prisma client and runtime toolchain are not explicitly tied together

The generated Prisma client embeds the build-time Prisma 6.19.3 engine path, and
`modules/litellm/lib.nix:82-85` overrides it at runtime with the consumer's
`pkgs.prisma-engines_6` and `pkgs.prisma_6`. In the normal case where the module
and package come from the same nixpkgs, these match. If a user imports the
overlay into a different nixpkgs, the generated client and runtime CLI/engine
can diverge.

The generated client also contains:

```python
SCHEMA_PATH = Path('/build/schema.prisma')
```

This is mostly cosmetic for PostgreSQL because the client falls back to
`PACKAGED_SCHEMA_PATH`, but it is still a build-path leak and can matter for
SQLite-related code.

Recommendations:

- Expose the Prisma CLI and engine used by the package via `passthru` and have
  the module use those values rather than hardcoding
  `pkgs.prisma_6`/`pkgs.prisma-engines_6`.
- Optionally patch `SCHEMA_PATH` in `postInstall` to point at
  `PACKAGED_SCHEMA_PATH` or `Path(__file__).parent / 'schema.prisma'`.
- Add a build-time or smoke-test import of `litellm.proxy.proxy_server` with the
  correct `LD_LIBRARY_PATH`.

### 13. LiteLLM's Darwin platform claim is not backed by the wrapper

`packages/litellm/default.nix:90-97` wraps binaries with `LD_LIBRARY_PATH`. On
macOS, `DYLD_LIBRARY_PATH` is the relevant variable, and the Prisma/UI behavior
is untested. `meta.platforms` at `packages/litellm/default.nix:110-114` still
declares `aarch64-darwin`.

Either:

- remove Darwin from `meta.platforms` and `supportedSystems` until it is
  tested, or
- add Darwin-specific wrapping and CI coverage.

The same "untested Darwin" caveat applies more broadly to the flake, but
LiteLLM is the most likely to fail at runtime.

### 14. Update scripts can silently write bad data

- `packages/copilot/update.sh` and `packages/headroom/update.sh` lack
  `set -euo pipefail`.
- `packages/headroom/update.sh:6` uses `curl -s` instead of `curl -fsS`.
- `packages/copilot/update.sh:8-13` and `packages/headroom/update.sh:10-23` do
  not validate that the fetched version and hashes are non-empty before writing
  JSON.
- `packages/litellm/update.sh:7` uses GNU-only `grep -oP`, line 14 uses
  `sed -i`, and line 5 uses `realpath`; those are not portable to macOS, despite
  the flake supporting Darwin.

A network error can therefore produce empty hashes or a `null` version and still
"successfully" update the JSON files. Add strict mode, `curl -fsS`, `jq -e`, and
explicit non-empty checks. Replace the GNU-specific `grep`/`sed` with portable
constructs or run the update only on Linux.

### 15. README gaps

- The standalone Home Manager snippet (`README.md:99-119`) does not show how to
  apply the overlay in a standalone Home Manager configuration. It only mentions
  the overlay for the "Home Manager as a NixOS module" case. Show
  `nixpkgs.overlays = [ harness-jail.overlays.default ];` in the standalone
  example as well.
- The README says `environmentFile` is not copied into the Nix store
  (`README.md:463-465`) but does not warn that it is readable from inside the
  sandbox if it lives under a mounted path. See item 1.
- The README says `environment` takes precedence over the file, but not that
  `HOME`/`PATH`/`SSL_CERT_FILE` defaults also win under `clearEnv`. See item 8.
- `README.md:301` says the LiteLLM package defaults to `pkgs.litellm`; it should
  also warn that forgetting the overlay silently selects nixpkgs' incomplete
  LiteLLM. Consider adding a `lib.warn` or assertion when `cfg.package` lacks
  the expected proxy marker.
- `README.md:343` says the Headroom CLI is installed alongside the service; the
  equivalent statement is missing for LiteLLM, and the NixOS module does not
  install it.

### 16. Test coverage is mostly liveness-only

- `example/nixos-opencode-litellm/default.nix:78-85` only checks
  `/health/liveliness`. That can pass even if Prisma setup or DB-backed features
  fail. Add a DB-backed request or verify that LiteLLM created its
  tables/migrations.
- The same applies to `example/home-manager-opencode-litellm/default.nix:93-101`.
- `example/nixos-harness-one-shot/default.nix:35-41` runs only as root. Add an
  unprivileged-user case.
- Add `machine.succeed("litellm --version")` to the NixOS test; it would catch
  the missing `systemPackages` entry.
- The LiteLLM tests set secrets in `/run/litellm.env` with mode `0644`
  (`example/nixos-opencode-litellm/default.nix:71-73`). In a test this is
  acceptable, but for an example use `0600` and the service user, or
  `0640 root:litellm`.

## Low priority / nits

- `modules/litellm/nixos.nix:1` and `modules/litellm/home-manager.nix:1` contain
  stale comments referencing `nix/litellm/...` paths.
- `.gitignore:2` contains `./result`, which is odd; `result` and `result-*`
  already cover it.
- `README.md:628` says the update shell includes `nodejs`; the flake uses
  `nodejs_latest` (`flake.nix:52`).
- `example/devenv-copilot/devenv.yaml:5-7` and
  `example/devenv-opencode-litellm/devenv.yaml:5-7` declare an unused
  `sops-nix` input. Remove it to reduce lock/update noise.
- `example/nixos-opencode-litellm/default.nix:4` has `lib ? pkgs.lib`; `lib` is
  already provided by the NixOS module system, so the default is unnecessary.
- `packages/litellm/default.nix:99-115` has no `meta.mainProgram`.
  `nix run .#litellm` currently works, but an explicit
  `mainProgram = "litellm"` is clearer.
- The repository has no top-level `LICENSE`. Add one so users know the terms of
  the flake/modules.
- CI does not run a formatter check. Add something like
  `nix run nixpkgs#alejandra -- --check .` or `nix fmt -- --check`.
- `update.yml:46-48` still says "Update version of Headroom" even though it
  updates all packages. Rename it.
- `update.yml` invokes `nix develop` without `--accept-flake-config`; add it for
  consistent substituter use.
- `packages/headroom/default.nix` depends on `python3.pkgs.litellm` from
  nixpkgs, not the flake's full LiteLLM. That may be fine for a library
  dependency, but it is worth verifying that Headroom does not need any proxy
  extras and that the version remains compatible.
- `modules/harness/lib.nix:21-25` allows `wrapperName` values like `.` and `..`
  because the regex is `[A-Za-z0-9._-]+`. Tighten it to start with an
  alphanumeric character or add an explicit check.
- Harness sets only `SSL_CERT_FILE`; Headroom/LiteLLM also set
  `REQUESTS_CA_BUNDLE` and/or `CURL_CA_BUNDLE`. Add those to Harness for tools
  that ignore `SSL_CERT_FILE`. Headroom already sets `REQUESTS_CA_BUNDLE` but
  not `CURL_CA_BUNDLE`.

## Suggested order of work

1. Fix the example security problems and the NixOS wrapper/homeDir split.
2. Refresh the three `devenv.lock` files.
3. Make the overlay use `final.callPackage` for all three packages.
4. Deduplicate/cache the CI pipeline and add resource limits.
5. Address the LiteLLM runtime details: `/bin/sh`, `LITELLM_UI_PATH`, telemetry
   defaults, Prisma toolchain, and NixOS `systemPackages`.
6. Harden update scripts and fill the documentation/test gaps.
7. Add a top-level `LICENSE` and a formatting CI check.
