# harness-jail

Run LLM coding agents and supporting proxies inside a small, declarative
[Bubblewrap](https://github.com/containers/bubblewrap) sandbox.

The flake provides reusable modules for **NixOS**, **Home Manager**, and
**devenv**, plus packages for a few common tools. You bring the CLI — Copilot,
opencode, or anything else — and the module builds a wrapper that runs it in a
jail with only the files, environment, and network access you allow.

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [How the sandbox works](#how-the-sandbox-works)
- [Module reference](#module-reference)
- [Headroom proxy](#headroom-proxy)
- [LiteLLM proxy](#litellm-proxy)
- [Packages and overlay](#packages-and-overlay)
- [Recipes](#recipes)
- [Examples](#examples)
- [Troubleshooting](#troubleshooting)
- [Development](#development)

## What it does

| Piece | What it gives you |
| --- | --- |
| `harness-jail` module | Wraps any CLI in a Bubblewrap sandbox. Installs a `harness` command and optionally runs the sandboxed command as a systemd service. |
| `headroom` module | Runs the [Headroom](https://github.com/headroomlabs-ai/headroom) context-optimization proxy, sandboxed, as a service. |
| `litellm` module | Runs the [LiteLLM](https://github.com/BerriAI/litellm) proxy with a Nix-configured JSON config, sandboxed, as a service. |
| Packages | `copilot` (GitHub Copilot CLI), `headroom`, and `litellm-prisma`. |

By default the sandbox:

- starts from an empty environment;
- exposes no host home directory and no host credentials;
- sees the Nix store read-only and a throwaway `/tmp`;
- has no network access;
- has a dedicated, persistent `homeDir` bind-mounted read-write.

Network access and extra host paths are opt-in.

## Requirements

- Linux. The sandbox modules rely on Bubblewrap, which is Linux-only.
- Nix with flakes enabled.
- NixOS, Home Manager, or devenv, depending on which module you use.
- Bubblewrap itself is added automatically; you do not need to install it.

Package outputs are declared for Linux and macOS systems, but only Linux is
tested and the sandbox modules are intended for Linux.

## Quick start

### 1. Add the flake input

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    harness-jail.url = "github:scarisey/harness-jail";
  };
}
```

### 2. NixOS

Import the module and enable the overlay if you want `pkgs.copilot` or
`pkgs.headroom`:

```nix
{
  outputs = { nixpkgs, harness-jail, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        harness-jail.nixosModules.harness-jail
        ({ pkgs, ... }: {
          nixpkgs.overlays = [ harness-jail.overlays.default ];

          services.harness-jail = {
            enable = true;
            package = pkgs.copilot;
            command = "copilot";
            enableNetwork = true;
            args = [ "--yolo" ];
          };
        })
      ];
    };
  };
}
```

After `nixos-rebuild switch`, run `harness --version`. A systemd service named
`harness-jail` also runs the sandboxed command at boot. To install only the
wrapper, set `daemon = false`.

### 3. Home Manager

```nix
{
  home-manager.users.me = { pkgs, ... }: {
    imports = [ harness-jail.homeManagerModules.harness-jail ];

    services.harness-jail = {
      enable = true;
      package = pkgs.copilot;
      command = "copilot";
      enableNetwork = true;
    };
  };
}
```

The wrapper is installed in `home.packages`, and the sandboxed command runs as a
systemd user service at login. If Home Manager is used as a NixOS module, set
`nixpkgs.overlays = [ harness-jail.overlays.default ];` in the NixOS
configuration so that `pkgs.copilot` is available.

### 4. devenv

Add the input to `devenv.yaml`:

```yaml
inputs:
  nixpkgs:
    url: github:cachix/devenv-nixpkgs/rolling
  harness-jail:
    url: github:scarisey/harness-jail
    flake: true
```

Import the module and configure it in `devenv.nix`:

```nix
{
  inputs,
  pkgs,
  ...
}: {
  imports = [ inputs.harness-jail.devenvModules.harness-jail ];
  overlays = [ inputs.harness-jail.overlays.default ];

  services.harness-jail = {
    enable = true;
    package = pkgs.copilot;
    command = "copilot";
    enableNetwork = true;
    homeDir = ./.home;
  };
}
```

Create `.home` before entering the shell. In devenv, `homeDir` has no default and
must be set explicitly. The project root is mounted read-write automatically, so
agents can edit the current project.

Run the wrapper with:

```sh
mkdir -p .home
devenv shell -- harness --version
```

The devenv harness module never starts a service; it only installs the wrapper as
a devenv script.

## How the sandbox works

### Wrapper and daemon

The harness module always builds a wrapper named `harness` (configurable with
`wrapperName`). Arguments passed to `harness` are forwarded to the configured
`command` after any `services.harness-jail.args`.

With NixOS and Home Manager, `daemon = true` (the default) additionally creates
a systemd unit that runs the same sandboxed command:

| Platform | Unit | Runs as | Starts at |
| --- | --- | --- | --- |
| NixOS | `systemd.services.harness-jail` | `harness-jail` system user | Boot |
| Home Manager | `systemd.user.services.harness-jail` | Your user | Login |

Set `daemon = false` to skip the unit and keep only the wrapper.

### Home directory and state

`homeDir` is bind-mounted read-write at the same path inside the sandbox. When
the environment is cleared, `HOME` is set to this directory, so application
state stored there persists between runs.

| Platform | Default `homeDir` |
| --- | --- |
| NixOS | `/var/lib/harness-jail` |
| Home Manager | `~/.local/state/harness-jail` |
| devenv | Required — no default |

Apart from the sandbox plumbing (`/nix`, `/dev`, `/proc`, `/tmp`, and the
resolver and CA files), only `homeDir`, `readOnlyPaths`, and `readWritePaths` are
exposed. The host home directory and its credentials are not visible unless you
explicitly mount them. In devenv, the project root is added to the read-write
paths automatically.

The sandbox also gets a temporary writable `/tmp` (a tmpfs), discarded when the
sandbox exits, unless you mount a host path there. To use a different in-sandbox
home, set
`services.harness-jail.environment.HOME` and make sure that directory is
reachable through `homeDir`, `readOnlyPaths`, or `readWritePaths`.

### Environment variables

With `clearEnv = true` (the default), the host environment is discarded. Only
these variables reach the sandbox:

- `HOME`, set to `homeDir`;
- `PATH`, built from `extraPackages` and the wrapped package;
- `SSL_CERT_FILE`, set to the Nix CA bundle;
- values from `environment`;
- variables loaded from `environmentFile`.

Set `clearEnv = false` to inherit the host environment. In that case there is no
default `HOME` override.

`environmentFile` points to a shell-compatible file that is read at runtime and
is not copied into the Nix store. Explicit values in `environment` take
precedence over the file. The file must be readable by the user or service that
runs the harness.

### Network and certificates

Network access is disabled by default. Set `enableNetwork = true` to share the
host network namespace.

Even with networking disabled, the sandbox mounts `/etc/resolv.conf` and the Nix
CA bundle at `/etc/ssl/certs/ca-certificates.crt`. The host's custom CA
certificates are not included. If you need them, mount a bundle with
`readOnlyPaths` and point `SSL_CERT_FILE` at it.

### Default tools

The sandbox includes a small set of common tools:

```text
bash coreutils gnugrep gnused gawk findutils diffutils gnutar gzip which git curl ripgrep
```

`/bin/sh` and `/usr/bin/env` are symlinked to Nix binaries. Apart from the
resolver and CA files described above, no host `/usr`, `/bin`, or `/etc` contents
are exposed, and no setuid binaries are available.

## Module reference

### `services.harness-jail`

Available as `nixosModules.harness-jail`, `homeManagerModules.harness-jail`, and
`devenvModules.harness-jail`.

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `enable` | bool | `false` | Enable the sandbox wrapper. |
| `package` | package | — | Package providing the CLI to wrap. **Required.** |
| `command` | string | — | Executable name to run inside the sandbox. **Required.** |
| `daemon` | bool | `true` | Create a systemd unit. Ignored by devenv. |
| `wrapperName` | string | `"harness"` | Name of the installed wrapper command. |
| `args` | list of string | `[]` | Arguments prepended to the executable. |
| `extraPackages` | list of package | common tools | Packages added to `PATH` inside the sandbox. |
| `enableNetwork` | bool | `false` | Share the host network namespace. |
| `readOnlyPaths` | list of path | `[]` | Host paths mounted read-only at the same path. |
| `readWritePaths` | list of path | `[]` | Host paths mounted read-write at the same path. |
| `clearEnv` | bool | `true` | Discard the host environment. |
| `environment` | attrs of string | `{}` | Environment variables set in the sandbox. |
| `environmentFile` | string or null | `null` | Runtime env file sourced by the wrapper. |
| `homeDir` | path | platform-specific | Persistent home directory for the sandbox. |

### `services.headroom`

Available as `nixosModules.headroom`, `homeManagerModules.headroom`, and
`devenvModules.headroom`. See [Headroom proxy](#headroom-proxy).

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `enable` | bool | `false` | Enable the Headroom proxy. |
| `package` | package | bundled Headroom | Headroom package to run. |
| `host` | string | `"127.0.0.1"` | Listen address. |
| `port` | port | `8787` | Listen port. |
| `environment` | attrs of string | `{}` | Environment variables for Headroom. |
| `environmentFile` | path or null | `null` | Env file loaded inside the sandbox. |
| `extraFlags` | list of string | `[]` | Extra flags passed to `headroom proxy`. |
| `readOnlyPaths` | list of path | `[]` | Extra read-only mounts. |
| `readWritePaths` | list of path | `[]` | Extra read-write mounts. |

### `services.litellm`

Available as `nixosModules.litellm`, `homeManagerModules.litellm`, and
`devenvModules.litellm`. See [LiteLLM proxy](#litellm-proxy).

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `enable` | bool | `false` | Enable the LiteLLM proxy. |
| `package` | package | `pkgs.litellm` | LiteLLM package to run. |
| `host` | string | `"127.0.0.1"` | Listen address. |
| `port` | port | `4000` | Listen port. |
| `environment` | attrs of string | `{}` | Environment variables for LiteLLM. |
| `environmentFile` | path or null | `null` | Env file bind-mounted at `/etc/litellm/env`. |
| `extraFlags` | list of string | `[]` | Extra flags passed to `litellm`. |
| `settings` | JSON value | `{}` | LiteLLM config, written as JSON. |

### State directories and service managers

| Module | NixOS state | Home Manager state | devenv state |
| --- | --- | --- | --- |
| `harness-jail` | `/var/lib/harness-jail` | `~/.local/state/harness-jail` | `homeDir` (required) |
| `headroom` | `/var/lib/headroom` | `~/.local/share/headroom` | `$DEVENV_STATE/headroom` |
| `litellm` | `/var/lib/litellm` | `~/.local/share/litellm` | `$DEVENV_STATE/litellm` |

NixOS uses system services, Home Manager uses user services, and devenv uses
scripts or processes as appropriate.

## Headroom proxy

[Headroom](https://github.com/headroomlabs-ai/headroom) compresses tool output and
LLM context through a local proxy. Enable it with:

```nix
{
  services.headroom = {
    enable = true;
    port = 8787;
    environment = {
      HEADROOM_MODE = "cache";
    };
  };
}
```

The proxy listens on `127.0.0.1:8787` by default. Point:

- Anthropic-compatible clients at `http://127.0.0.1:8787`;
- OpenAI-compatible clients at `http://127.0.0.1:8787/v1`;
- liveness checks at `http://127.0.0.1:8787/livez`.

The `headroom` CLI is installed alongside the service. The proxy always shares
the host network namespace and always clears its environment. Pass provider
credentials and other settings with `environment` or `environmentFile`.

`environmentFile` is bind-mounted read-only at `/etc/headroom/env` and sourced
inside the sandbox. Values in `environment` take precedence over the file. Use a
string path such as `/run/secrets/headroom.env`; a Nix path literal may be copied
into the Nix store. Add extra host paths with `readOnlyPaths` and
`readWritePaths`; extra `headroom proxy` arguments go in `extraFlags`.

## LiteLLM proxy

The LiteLLM module runs [LiteLLM](https://github.com/BerriAI/litellm) as a
sandboxed proxy with a declarative configuration:

```nix
{
  services.litellm = {
    enable = true;
    port = 4000;
    environment = {
      LITELLM_MASTER_KEY = "sk-change-me";
      ANTHROPIC_API_KEY = "sk-ant-change-me";
      DATABASE_URL = "postgresql://litellm:litellm@127.0.0.1:5432/litellm";
      STORE_MODEL_IN_DB = "True";
    };
    settings = {
      model_list = [
        {
          model_name = "claude";
          litellm_params = {
            model = "anthropic/claude-sonnet-4";
            api_key = "os.environ/ANTHROPIC_API_KEY";
          };
        }
      ];
      general_settings = {
        master_key = "os.environ/LITELLM_MASTER_KEY";
      };
    };
  };
}
```

`settings` is converted to JSON and mounted at `/etc/litellm/config.json`.
Liveness is exposed at `/health/liveliness`.

Values in `environment` become part of the Nix store. The example above uses
placeholders; do not commit real credentials to a Nix file.

The LiteLLM sandbox always shares the host network namespace so it can reach
model providers and databases. The service includes a Nix-compatible Prisma
setup, so database-backed LiteLLM features work without downloading Prisma
engines at runtime.

> **NixOS:** nixpkgs also defines `services.litellm`. When importing this
> flake's module, disable the upstream module first:
>
> ```nix
> {
>   disabledModules = [ "services/misc/litellm.nix" ];
>   imports = [ harness-jail.nixosModules.litellm ];
> }
> ```

> **Current limitation:** `environmentFile` is bind-mounted at
> `/etc/litellm/env`, but it is not yet sourced inside the sandbox. Use
> `environment` for values that must reach the process.

## Packages and overlay

The flake exports:

| Output | Description |
| --- | --- |
| `packages.<system>.copilot` | GitHub Copilot CLI (`copilot`). |
| `packages.<system>.headroom` | Headroom AI (`headroom`). |
| `packages.<system>.litellm-prisma` | LiteLLM with a pre-generated Prisma client. |
| `overlays.default` | Adds `pkgs.copilot` and `pkgs.headroom`. |

Build a package directly:

```sh
nix build .#copilot
nix build .#headroom
```

or use the overlay:

```nix
{
  nixpkgs.overlays = [ inputs.harness-jail.overlays.default ];
}
```

`overlays.default` does **not** add `litellm-prisma`; reference it from the flake
outputs if you need it.

## Recipes

### Load secrets from a file

```nix
{
  services.harness-jail = {
    enable = true;
    package = pkgs.copilot;
    command = "copilot";
    enableNetwork = true;
    environmentFile = "/run/secrets/copilot.env";
  };
}
```

The file is read at runtime and is not copied into the Nix store when referenced
as a string path. Use a runtime path such as `/run/secrets/copilot.env`; a Nix
path literal may be copied into the store. The file should contain
shell-compatible assignments:

```sh
export COPILOT_GITHUB_TOKEN="ghp_..."
```

The same pattern works for Headroom. For LiteLLM, see the current
`environmentFile` limitation below.

### Give the agent access to a project

```nix
{
  services.harness-jail = {
    enable = true;
    package = pkgs.copilot;
    command = "copilot";
    enableNetwork = true;
    readWritePaths = [ "/home/me/src/my-project" ];
  };
}
```

In devenv, the project root is mounted read-write automatically.

### Run a custom tool

`harness-jail` is not tied to an LLM CLI:

```nix
{
  services.harness-jail = {
    enable = true;
    package = pkgs.hello;
    command = "hello";
    daemon = false;
  };
}
```

### Use custom CA certificates

```nix
{
  services.harness-jail = {
    enable = true;
    package = pkgs.copilot;
    command = "copilot";
    enableNetwork = true;
    readOnlyPaths = [ "/etc/ssl/certs/my-ca.pem" ];
    environment.SSL_CERT_FILE = "/etc/ssl/certs/my-ca.pem";
  };
}
```

### Change the wrapper name

```nix
{
  services.harness-jail.wrapperName = "agent";
}
```

Then run `agent` instead of `harness`.

## Examples

The [`example/`](./example) directory contains complete, runnable setups:

| Example | Demonstrates |
| --- | --- |
| [`devenv-copilot`](./example/devenv-copilot) | Copilot CLI with a secretspec env file and the project mounted read-write. |
| [`devenv-opencode-simple`](./example/devenv-opencode-simple) | Minimal opencode setup. |
| [`devenv-opencode-litellm`](./example/devenv-opencode-litellm) | opencode plus LiteLLM and PostgreSQL in devenv. |
| [`home-manager-opencode-litellm`](./example/home-manager-opencode-litellm) | Home Manager harness and LiteLLM user services, with a NixOS test. |
| [`nixos-harness-one-shot`](./example/nixos-harness-one-shot) | NixOS wrapper with `daemon = false`. |
| [`nixos-headroom`](./example/nixos-headroom) | Headroom service and liveness check. |
| [`nixos-opencode-litellm`](./example/nixos-opencode-litellm) | NixOS opencode plus LiteLLM and PostgreSQL, with a NixOS test. |

## Troubleshooting

### `harness: command not found`

- NixOS: rebuild with `nixos-rebuild switch`.
- Home Manager: run `home-manager switch` and open a new shell.
- devenv: run `devenv shell -- harness --version`.
- If you changed `wrapperName`, use that name instead.

### A service fails to start

```sh
# NixOS
systemctl status harness-jail
journalctl -u harness-jail

# Home Manager
systemctl --user status harness-jail
journalctl --user -u harness-jail
```

Use the same commands with `headroom` or `litellm` instead of `harness-jail` for
those services. For devenv, harness is a script; start the Headroom and LiteLLM
processes with `devenv up` and check its output.

### The agent has no network access

Set `enableNetwork = true`. Networking is disabled by default, including DNS.
If you use custom certificates, mount them with `readOnlyPaths` and set
`SSL_CERT_FILE`.

### The agent cannot see my files or credentials

This is intentional. Only `homeDir`, `readOnlyPaths`, `readWritePaths`, and (in
devenv) the project root are visible from your host files. Add the paths you need
explicitly.

### Environment variables are missing

With `clearEnv = true`, only `environment`, `environmentFile`, and the variables
listed in [Environment variables](#environment-variables) reach the sandbox. Set
`clearEnv = false` to inherit the host environment.

### Changes in devenv are not visible in the sandbox

Only the project root, `homeDir`, and explicit `readOnlyPaths`/`readWritePaths`
are mounted from your host files. Files outside those paths do not exist inside
the sandbox.

### NixOS reports conflicting `services.litellm` options

Disable the upstream module before importing this one:

```nix
{
  disabledModules = [ "services/misc/litellm.nix" ];
}
```

### `environmentFile` does not work with LiteLLM

This is a known limitation in the current module. The file is mounted, but not
sourced. Use `environment` or a wrapper that exports the values before starting
the service.

### The sandbox modules do not work on macOS

Bubblewrap requires Linux. Some packages may build on macOS, but the sandbox
modules do not.

## Development

```sh
# Evaluate and run the NixOS VM tests (Linux)
nix flake check

# Build individual packages
nix build .#copilot
nix build .#headroom

# Update package versions
nix develop .#updateShell
./packages/copilot/update.sh
./packages/headroom/update.sh

# Format Nix sources
nix fmt
```

The `updateShell` includes `nodejs` and `jq` and prints the available `update.sh`
scripts. The update scripts also need `nix`, `curl`, and `npm` where applicable.

The flake's checks are NixOS VM tests and therefore run only on Linux.
