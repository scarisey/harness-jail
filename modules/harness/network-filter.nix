{
  lib,
  pkgs,
}: let
  inherit
    (lib)
    any
    concatStringsSep
    elem
    optionalString
    stringToCharacters
    ;

  # Port used on the sandbox loopback and on the host's private proxy address.
  localPort = 8888;

  # Filtering flow:
  #   sandboxed client -> 127.0.0.1:8888 (in-sandbox socat relay)
  #     -> /run/harness-jail/proxy.sock (read-only bind mount)
  #     -> host socat bridge -> tinyproxy on a private 127/8 address
  #     -> host network, filtered by the hostname allowlist.
  #
  # The sandbox keeps its isolated network namespace; the bind-mounted Unix
  # socket is the only path out.
  #
  # Patterns are passed to tinyproxy verbatim and matched with libc
  # fnmatch(3) (FilterType fnmatch): `*`, `?`, `[abc]`, and `[!abc]`, against
  # the whole hostname. fnmatch is case-sensitive, so patterns should be
  # lowercase. A malformed pattern simply never matches, and FilterDefaultDeny
  # keeps that fail-closed.

  validatePattern = pattern:
    if pattern == ""
    then throw "services.harness-jail.networkFilter.patterns must not contain empty strings"
    else if any (c: elem c [" " "\t" "\n" "\r" "#"]) (stringToCharacters pattern)
    then throw "services.harness-jail.networkFilter.patterns entry '${pattern}' contains whitespace or '#'"
    else pattern;
in {
  mk = {cfg}: let
    enabled =
      if cfg.networkFilter.patterns != [] && !cfg.enableNetwork
      then throw "services.harness-jail.networkFilter.patterns requires services.harness-jail.enableNetwork = true"
      else cfg.networkFilter.patterns != [];

    patterns = map validatePattern cfg.networkFilter.patterns;

    filterFile =
      pkgs.writeText "harness-jail-network-filter"
      (concatStringsSep "\n" patterns
        + optionalString enabled "\n");

    proxyEnv = {
      HTTP_PROXY = "http://127.0.0.1:${toString localPort}";
      HTTPS_PROXY = "http://127.0.0.1:${toString localPort}";
      ALL_PROXY = "http://127.0.0.1:${toString localPort}";
      http_proxy = "http://127.0.0.1:${toString localPort}";
      https_proxy = "http://127.0.0.1:${toString localPort}";
      all_proxy = "http://127.0.0.1:${toString localPort}";
      NO_PROXY = "";
      no_proxy = "";
    };

    # Starts a private tinyproxy in the host network namespace and exposes it
    # through a Unix socket. The sandbox cannot reach the host network
    # directly; it can only reach the bind-mounted socket.
    hostSetup = optionalString enabled ''
      proxy_base="''${XDG_RUNTIME_DIR:-/tmp}"
      if [ ! -d "$proxy_base" ]; then
        proxy_base=/tmp
      fi
      HARNESS_JAIL_PROXY_DIR="$(${pkgs.coreutils}/bin/mktemp -d "$proxy_base/harness-jail-proxy.XXXXXX")"

      HARNESS_JAIL_PROXY_ADDR="127.$((RANDOM % 254 + 1)).$((RANDOM % 254 + 1)).$((RANDOM % 254 + 2))"

      ${pkgs.coreutils}/bin/cat >"$HARNESS_JAIL_PROXY_DIR/tinyproxy.conf" <<EOF
      Port ${toString localPort}
      Listen $HARNESS_JAIL_PROXY_ADDR
      Timeout 3600
      MaxClients 100
      Allow 127.0.0.1
      LogFile "$HARNESS_JAIL_PROXY_DIR/tinyproxy.log"
      PidFile "$HARNESS_JAIL_PROXY_DIR/tinyproxy.pid"
      LogLevel Notice
      DisableViaHeader Yes
      Filter "${filterFile}"
      FilterType fnmatch
      FilterURLs Off
      FilterDefaultDeny Yes
      EOF

      ${pkgs.tinyproxy}/bin/tinyproxy -d -c "$HARNESS_JAIL_PROXY_DIR/tinyproxy.conf" \
        >>"$HARNESS_JAIL_PROXY_DIR/tinyproxy.log" 2>&1 &
      HARNESS_JAIL_PROXY_PID=$!

      ${pkgs.socat}/bin/socat \
        UNIX-LISTEN:"$HARNESS_JAIL_PROXY_DIR/proxy.sock",fork,mode=0600 \
        TCP:"$HARNESS_JAIL_PROXY_ADDR:${toString localPort}" \
        </dev/null >>"$HARNESS_JAIL_PROXY_DIR/bridge.log" 2>&1 &
      HARNESS_JAIL_PROXY_BRIDGE_PID=$!

      proxy_ready=0
      for _ in {1..100}; do
        if [ -S "$HARNESS_JAIL_PROXY_DIR/proxy.sock" ] \
          && ${pkgs.socat}/bin/socat -u OPEN:/dev/null TCP:"$HARNESS_JAIL_PROXY_ADDR:${toString localPort}" 2>/dev/null; then
          proxy_ready=1
          break
        fi
        if ! kill -0 "$HARNESS_JAIL_PROXY_PID" 2>/dev/null; then
          break
        fi
        if ! kill -0 "$HARNESS_JAIL_PROXY_BRIDGE_PID" 2>/dev/null; then
          break
        fi
        ${pkgs.coreutils}/bin/sleep 0.05
      done

      if [ "$proxy_ready" != 1 ]; then
        echo "harness-jail: failed to start the network filter proxy" >&2
        ${pkgs.coreutils}/bin/cat "$HARNESS_JAIL_PROXY_DIR/tinyproxy.log" >&2 || true
        ${pkgs.coreutils}/bin/cat "$HARNESS_JAIL_PROXY_DIR/bridge.log" >&2 || true
        exit 1
      fi
    '';

    cleanupDefinition = optionalString enabled ''
      proxy_cleanup() {
        status=$?
        trap - EXIT INT TERM

        if [ -n "''${HARNESS_JAIL_PROXY_BRIDGE_PID:-}" ]; then
          kill "$HARNESS_JAIL_PROXY_BRIDGE_PID" 2>/dev/null || true
          wait "$HARNESS_JAIL_PROXY_BRIDGE_PID" 2>/dev/null || true
        fi
        if [ -n "''${HARNESS_JAIL_PROXY_PID:-}" ]; then
          kill "$HARNESS_JAIL_PROXY_PID" 2>/dev/null || true
          wait "$HARNESS_JAIL_PROXY_PID" 2>/dev/null || true
        fi
        if [ -n "''${HARNESS_JAIL_PROXY_DIR:-}" ]; then
          ${pkgs.coreutils}/bin/rm -rf "$HARNESS_JAIL_PROXY_DIR"
        fi

        exit "$status"
      }
    '';

    # Runs inside the sandbox. It exposes a normal TCP proxy endpoint on
    # loopback and relays it over the bind-mounted Unix socket.
    relayScript = pkgs.writeShellScript "harness-jail-proxy-relay" ''
      set -eo pipefail

      ${pkgs.socat}/bin/socat \
        TCP-LISTEN:${toString localPort},fork,bind=127.0.0.1,reuseaddr \
        UNIX-CONNECT:/run/harness-jail/proxy.sock \
        </dev/null >/dev/null 2>&1 &
      relay_pid=$!

      ready=0
      for _ in {1..100}; do
        if ${pkgs.bash}/bin/bash -c 'exec 3<>/dev/tcp/127.0.0.1/${toString localPort}' 2>/dev/null; then
          ready=1
          break
        fi
        if ! kill -0 "$relay_pid" 2>/dev/null; then
          echo "harness-jail: proxy relay exited before becoming ready" >&2
          exit 1
        fi
        ${pkgs.coreutils}/bin/sleep 0.05
      done

      if [ "$ready" != 1 ]; then
        echo "harness-jail: proxy relay did not become ready" >&2
        exit 1
      fi

      exec "$@"
    '';
  in {
    inherit
      cleanupDefinition
      enabled
      filterFile
      hostSetup
      proxyEnv
      relayScript
      ;
  };
}
