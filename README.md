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
| Packages | `copilot` (GitHub Copilot CLI), `headroom`, and `litellm`. |

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

Copilot and Headroom are declared for Linux and Apple Silicon macOS, but only
Linux is tested. LiteLLM is Linux-only, and the sandbox modules are intended
for Linux.

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

Import the module and enable the overlay if you want `pkgs.copilot`,
`pkgs.headroom`, or `pkgs.litellm`:

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

    nixpkgs.overlays = [ harness-jail.overlays.default ];

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

Create `.home` before entering the shell. In devenv, `homeDir` falls back to a
per-user state directory when unset, but an explicit project-local directory is
recommended. The project root is mounted read-write automatically, so agents can
edit the current project.

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
| NixOS wrapper | `~/.local/state/harness-jail` (per invoking user) |
| NixOS daemon | `/var/lib/harness-jail` |
| Home Manager | `~/.local/state/harness-jail` |
| devenv | `~/.local/state/harness-jail` if unset, but setting an explicit project-local directory is recommended |

Apart from the sandbox plumbing (`/nix/store`, `/dev`, `/proc`, `/tmp`, and the
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
- `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, and `CURL_CA_BUNDLE`, set to the Nix CA
  bundle;
- values from `environmentFile`;
- values from `environment`.

Built-in defaults are applied first, then `environmentFile`, then explicit
`environment` values. This means an env file can override `HOME`, the CA
variables, and the base `PATH`, while explicit `environment` values still take
precedence over both. The wrapper always prepends the wrapped package and
`extraPackages` to `PATH`, so the command and its tools remain runnable.

Set `clearEnv = false` to inherit the host environment. In that case there is no
default `HOME` override.

`environmentFile` points to a shell-compatible file that is read at runtime and
is not copied into the Nix store. The file is sourced outside the sandbox and
then masked at its original path inside the sandbox, so the sandboxed process
cannot read it even when it lives under `homeDir`, `readWritePaths`, or the
devenv root. The file must be readable by the user or service that runs the
harness. A symlink or duplicate copy under another mounted path is still
readable; store secrets outside mounted paths when possible.

### Network and certificates

Network access is disabled by default. Set `enableNetwork = true` to share the
host network namespace.

To allow only selected hosts, keep `enableNetwork = true` and set
`networkFilter.patterns`:

```nix
{
  services.harness-jail = {
    enableNetwork = true;
    networkFilter.patterns = [
      "api.openai.com"
      "*.openai.com"
      "127.0.0.1"
    ];
  };
}
```

With patterns set, the sandbox does **not** share the host network namespace. It
gets a loopback-only network and a local proxy endpoint, and the wrapper sets
`HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, and their lowercase forms to point at
that endpoint. These values are applied after `environment` and
`environmentFile`, so they cannot be redirected to another proxy. A filtering
proxy runs in the host network namespace and forwards only requests whose
hostname matches the allowlist. Direct connections to external hosts and DNS
queries from inside the sandbox are not available.

Patterns match the request hostname only. They do not match the scheme, path,
query, or port, so allowlisting a host permits every port on that host. Matching
is case-sensitive, so write patterns in lowercase; a client that sends a
mixed-case host (for example `API.example.com`) is denied. Supported glob
syntax:

| Syntax | Matches |
| --- | --- |
| `*` | any sequence of characters, including dots |
| `?` | exactly one character |
| `[abc]` | one character from the set |
| `[!abc]` | one character not in the set |

For example, `*.example.com` matches `api.example.com` and
`deep.api.example.com`, but not `example.com` itself. List both patterns when
you need both. Patterns must not contain whitespace or `#`.

Only clients that honor the standard proxy environment variables can use the
network. Applications that ignore them fail closed. SSH, raw TCP, QUIC/HTTP3,
and other non-HTTP protocols are not proxied and are unavailable while
filtering. HTTPS uses `CONNECT`; there is no TLS interception, so the sandbox
still validates the real server certificate.

Allowlisting a loopback or private address grants access to everything the
harness user can reach at that address. For example, allowlisting `127.0.0.1`
makes every host-local port reachable through the proxy.

`networkFilter.patterns` requires `enableNetwork = true`. An empty list disables
filtering and restores normal `enableNetwork` behavior.

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
| `enableNetwork` | bool | `false` | Share the host network namespace, or enable the allowlist proxy when `networkFilter.patterns` is set. |
| `networkFilter.patterns` | list of string | `[]` | Hostname allowlist globs, matched case-sensitively. Requires `enableNetwork = true`; empty disables filtering. |
| `readOnlyPaths` | list of path | `[]` | Host paths mounted read-only at the same path. |
| `readWritePaths` | list of path | `[]` | Host paths mounted read-write at the same path. |
| `clearEnv` | bool | `true` | Discard the host environment. |
| `environment` | attrs of string | `{}` | Environment variables set in the sandbox. |
| `environmentFile` | string or null | `null` | Runtime env file sourced by the wrapper and masked inside the sandbox. |
| `homeDir` | path or null | platform-specific | Persistent home directory. `null` uses a per-user runtime state directory. |

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
| `environmentFile` | string or null | `null` | Env file loaded inside the sandbox. |
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
| `environmentFile` | string or null | `null` | Env file bind-mounted at `/etc/litellm/env`. |
| `extraFlags` | list of string | `[]` | Extra flags passed to `litellm`. |
| `settings` | JSON value | `{}` | LiteLLM config, written as JSON. |

### State directories and service managers

| Module | NixOS state | Home Manager state | devenv state |
| --- | --- | --- | --- |
| `harness-jail` | `/var/lib/harness-jail` (daemon) | `~/.local/state/harness-jail` | `homeDir` or per-user default |
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

`environmentFile` is bind-mounted read-only at `/etc/headroom/env`, sourced
inside the sandbox, and masked at its original host path. Values in `environment`
take precedence over the file. Use a string path such as
`/run/secrets/headroom.env`; the value is not copied into the Nix store. Add
extra host paths with `readOnlyPaths` and `readWritePaths`; extra
`headroom proxy` arguments go in `extraFlags`.

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
placeholders; do not commit real credentials to a Nix file. Use
`environmentFile` for secrets: it is bind-mounted read-only at
`/etc/litellm/env`, sourced inside the sandbox at runtime, and masked at its
original host path inside the sandbox. Explicit values in `environment` take
precedence over the file.

The LiteLLM module defaults to the `SCARF_NO_ANALYTICS=True`,
`DO_NOT_TRACK=True`, and `ANONYMIZED_TELEMETRY=False` environment variables.
Override them in `environment` if needed.

The LiteLLM sandbox always shares the host network namespace so it can reach
model providers and databases. The default `services.litellm.package` is
`pkgs.litellm` from this flake's overlay; import the overlay to get a
full-server build with the proxy dependencies and a pre-generated Prisma client.
Database-backed features then work without downloading Prisma engines or a Node
toolchain at runtime. If the overlay is missing, nixpkgs' incomplete LiteLLM
package is selected and the module emits a warning.

The `litellm` CLI is installed alongside the service on NixOS, Home Manager, and
devenv.

> **NixOS:** nixpkgs also defines `services.litellm`. When importing this
> flake's module, disable the upstream module first:
>
> ```nix
> {
>   disabledModules = [ "services/misc/litellm.nix" ];
>   imports = [ harness-jail.nixosModules.litellm ];
> }
> ```

## Packages and overlay

The flake exports:

| Output | Description |
| --- | --- |
| `packages.<system>.copilot` | GitHub Copilot CLI (`copilot`). |
| `packages.<system>.headroom` | Headroom AI (`headroom`). |
| `packages.<system>.litellm` | LiteLLM proxy with the full server dependency set (Linux only). |
| `overlays.default` | Adds `pkgs.copilot`, `pkgs.headroom`, and, on Linux, `pkgs.litellm`. |

Build a package directly:

```sh
NIXPKGS_ALLOW_UNFREE=1 nix build --impure .#copilot
nix build .#headroom
nix build .#litellm
```

or use the overlay:

```nix
{
  nixpkgs.overlays = [ inputs.harness-jail.overlays.default ];
}
```

The overlay is required for the full LiteLLM build. nixpkgs also provides a
`litellm` package, but it does not include the proxy extras; importing the
overlay overrides it with the full-server package used by the modules. On
unsupported systems and on Darwin, the overlay only adds Copilot and Headroom.
LiteLLM is Linux-only.

`copilot` is unfree. Enable it with `nixpkgs.config.allowUnfree = true`, or set
`NIXPKGS_ALLOW_UNFREE=1` when building it directly.

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

The file is read at runtime and is not copied into the Nix store. Use a runtime
path such as `/run/secrets/copilot.env`. The file is masked at its original path
inside the sandbox, but it should still live outside `homeDir`, `readWritePaths`,
and the devenv project root when possible. The file should contain
shell-compatible assignments:

```sh
export COPILOT_GITHUB_TOKEN="ghp_..."
```

The same pattern works for Headroom and LiteLLM.

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

### Restrict network access to an allowlist

```nix
{
  services.harness-jail = {
    enable = true;
    package = pkgs.opencode;
    command = "opencode";
    enableNetwork = true;
    networkFilter.patterns = [
      "api.openai.com"
      "*.openai.com"
      "api.anthropic.com"
      "127.0.0.1"
    ];
  };
}
```

The sandbox can reach only the listed hostnames, through the built-in proxy.
Add every provider, package registry, and local service the harness needs. If a
workflow relies on SSH, raw TCP, or a tool that ignores proxy environment
variables, it will not work under filtering; use `enableNetwork = true` without
patterns for unrestricted networking instead.

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
| [`devenv-copilot`](./example/devenv-copilot) | Copilot CLI with a secretspec env file stored outside the project root and the project mounted read-write. |
| [`devenv-opencode-simple`](./example/devenv-opencode-simple) | Minimal opencode setup. |
| [`devenv-opencode-litellm`](./example/devenv-opencode-litellm) | opencode plus LiteLLM and PostgreSQL in devenv. |
| [`home-manager-opencode-litellm`](./example/home-manager-opencode-litellm) | Home Manager harness and LiteLLM user services, with a NixOS test. |
| [`nixos-harness-network-filter`](./example/nixos-harness-network-filter) | NixOS VM test for allowlisted HTTP access, denied hosts, and fail-closed direct connections. |
| [`nixos-harness-one-shot`](./example/nixos-harness-one-shot) | NixOS wrapper with `daemon = false`. |
| [`nixos-headroom`](./example/nixos-headroom) | Headroom service and liveness check. |
| [`nixos-opencode-litellm`](./example/nixos-opencode-litellm) | NixOS opencode plus LiteLLM and PostgreSQL, with a NixOS test. |

The `devenv-copilot` example reads its secret from
`~/.config/harness-jail/secrets/harness-flake/default/environment_file`, outside
the project root. Set it with `secretspec set environment_file` (or let the
first `devenv shell` prompt for it). Keeping it outside the project means the
sandbox's automatic read-write mount of the project root does not expose it.

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

### An allowlisted host is unreachable

- Check that `enableNetwork = true` is also set.
- Patterns match the hostname, not the URL. `https://api.example.com/v1` is
  matched as `api.example.com`.
- Matching is case-sensitive. Use lowercase patterns; a client that sends
  `API.example.com` will not match `api.example.com`.
- `*.example.com` does not match `example.com`; list both if needed.
- Verify that the application honors `HTTP_PROXY`, `HTTPS_PROXY`, or `ALL_PROXY`.
  From inside the sandbox, try `curl -v https://the-host/`.
- Filtering only proxies HTTP and HTTPS. SSH, raw TCP, QUIC/HTTP3, and other
  protocols do not work while filtering is enabled.

### The filtering proxy fails to start

The wrapper creates a private proxy directory under `${XDG_RUNTIME_DIR:-/tmp}`
and removes it on exit. Check that this directory is writable by the user or
service running the harness. If a previous run was killed with `SIGKILL`, a
stale `harness-jail-proxy.*` directory may remain in `/tmp`; it is safe to
remove.

### The agent cannot see my files or credentials

This is intentional. Only `homeDir`, `readOnlyPaths`, `readWritePaths`, and (in
devenv) the project root are visible from your host files. Add the paths you need
explicitly. `environmentFile` is masked at its original path inside the sandbox,
but symlinks or copies under other mounted paths can still expose it.

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

### The sandbox modules do not work on macOS

Bubblewrap requires Linux. Some packages may build on macOS, but the sandbox
modules do not.

## Development

```sh
# Evaluate and run the NixOS VM tests (Linux)
NIXPKGS_ALLOW_UNFREE=1 nix flake check --impure

# Build individual packages
NIXPKGS_ALLOW_UNFREE=1 nix build --impure .#copilot
nix build .#headroom
nix build .#litellm

# Update package versions
nix develop .#updateShell
./packages/copilot/update.sh
./packages/headroom/update.sh
./packages/litellm/update.sh

# Format Nix sources
nix fmt
```

The `updateShell` includes `nix`, `curl`, `jq`, `nodejs_latest`, `python3`, and
`uv`, and prints the available `update.sh` scripts.

The flake's checks are NixOS VM tests and therefore run only on Linux.

## License

The flake, modules, and examples are licensed under the Apache License 2.0. See
[`LICENSE`](./LICENSE).
