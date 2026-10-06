# LLM harness jail

Modules for NixOS, Home Manager, and devenv to put harness LLM in jail.

Import the module for your environment and configure an executable:

```nix
{ pkgs, ... }: {
  services.harness-jail = {
    enable = true;
    package = pkgs.copilot;
    command = "copilot";
    enableNetwork = true;
  };
}
```

With NixOS and Home Manager, the configured wrapper is installed in `PATH` as
`harness` by default; devenv exposes it as a script with the same name. Run
`harness --version` in those environments (`devenv shell -- harness --version`
for devenv). Arguments passed to `harness` are forwarded to the executable
after any configured `services.harness-jail.args`.

On NixOS, the module also defines `systemd.services.harness-jail`, which runs the
same sandboxed executable at boot as the `harness-jail` system user. Its state
directory is `/var/lib/harness-jail`, which is also the default
`services.harness-jail.homeDir` on NixOS. With Home Manager, the module defines
the equivalent `systemd.user.services.harness-jail`, started at login, with
`homeDir` defaulting to `~/.local/state/harness-jail`.

Set `services.harness-jail.daemon = false` to skip the systemd unit entirely.
The `harness` wrapper is still installed and can be run manually. This option
only affects the NixOS and Home Manager modules; devenv always exposes the
wrapper without starting it.

By default, the sandbox clears the host environment and sets `HOME` to
`services.harness-jail.homeDir`. That directory is bind-mounted read-write into
the sandbox, so application state stored under `$HOME` persists between runs.
The host home directory and credentials are not exposed unless `homeDir` or a
`readOnlyPaths`/`readWritePaths` entry points at them. The sandbox also gets a temporary
writable `/tmp` (a tmpfs), discarded when the sandbox exits. To use a different
in-sandbox home, set `services.harness-jail.environment.HOME` and make sure the
directory is reachable through `homeDir`, `readOnlyPaths`, or `readWritePaths`.
With `clearEnv = false`, the host environment is inherited without a default
HOME override. In devenv, `homeDir` has no default and must be set explicitly.

To load additional variables from a shell-compatible file, set
`services.harness-jail.environmentFile` to its path. The file is read at runtime
and is not copied into the Nix store. When `clearEnv = true`, only variables
from that file and `environment` are passed to the sandbox; explicit values in
`environment` take precedence. When `clearEnv = false`, the file is loaded in
addition to the inherited host environment.

Network access is disabled by default. Setting `enableNetwork = true` shares the
host network namespace. The sandbox mounts `/etc/resolv.conf` and the Nix CA
bundle at `/etc/ssl/certs/ca-certificates.crt` for DNS and HTTPS. With
`clearEnv = true`, `SSL_CERT_FILE` defaults to that bundle; an explicit value in
`environment` overrides it. The host's custom CA certificates are not included;
if needed, mount a custom bundle with `readOnlyPaths` and point `SSL_CERT_FILE`
to it. Paths other than the default mounts must be explicitly allowed with
`readOnlyPaths` or `readWritePaths`.

## Headroom proxy

The `headroom` modules run the [Headroom](https://github.com/headroomlabs-ai/headroom)
optimization proxy as a sandboxed service. Import `nixosModules.headroom`,
`homeManagerModules.headroom`, or `devenvModules.headroom`:

```nix
{...}: {
  services.headroom = {
    enable = true;
    port = 8787;
  };
}
```

The proxy listens on `127.0.0.1:8787` by default. Point Anthropic clients at
`http://127.0.0.1:8787`, or OpenAI-compatible clients at
`http://127.0.0.1:8787/v1`. Liveness is exposed at `/livez`.

On NixOS, the module defines `systemd.services.headroom`, running as the
`headroom` system user with state in `/var/lib/headroom`. With Home Manager it
defines `systemd.user.services.headroom` with state in
`~/.local/share/headroom`; devenv runs it as a process with state in
`$DEVENV_STATE/headroom`. The `headroom` CLI is installed alongside the service.

Like the harness jail, the proxy runs under Bubblewrap with a cleared
environment and the host network shared. Pass provider credentials and other
settings with `services.headroom.environment` or a shell-compatible
`services.headroom.environmentFile`. The environment file is bind-mounted
read-only and sourced inside the sandbox, and is not copied into the Nix store.
Explicit values in `environment` take precedence over the file.
Additional host paths can be exposed with `readOnlyPaths` and `readWritePaths`.
Arguments in `extraFlags` are forwarded to `headroom proxy`.
