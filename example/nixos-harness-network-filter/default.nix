{
  self,
  pkgs,
  ...
}:
pkgs.testers.nixosTest {
  name = "nixos-harness-network-filter";

  nodes.machine = {pkgs, ...}: let
    targetRoot = pkgs.writeTextDir "index.html" "allowed\n";
  in {
    imports = [
      self.nixosModules.harness-jail
    ];

    virtualisation = {
      memorySize = 2048;
      cores = 2;
    };

    users.users.alice = {
      isNormalUser = true;
      home = "/home/alice";
    };

    # All names resolve to the same local HTTP server. The filter must
    # distinguish them by hostname even though the port is identical.
    networking.hosts."127.0.0.1" = ["allowed.test" "denied.test" "sub.allowed.test"];

    systemd.services.http-target = {
      wantedBy = ["multi-user.target"];
      script = ''
        exec ${pkgs.python3}/bin/python3 -m http.server 8000 \
          --bind 127.0.0.1 --directory ${targetRoot}
      '';
    };

    services.harness-jail = {
      enable = true;
      daemon = false;
      package = pkgs.writeShellScriptBin "network-filter-check" ''
        set -eu

        test "$(curl -fsS http://allowed.test:8000/)" = "allowed"
        test "$(curl -fsS http://sub.allowed.test:8000/)" = "allowed"
        test "$(curl -sS -o /dev/null -w '%{http_code}' http://denied.test:8000/)" = "403"

        # Matching is case-sensitive: the same host with different case is
        # not covered by the lowercase pattern.
        test "$(curl -sS -o /dev/null -w '%{http_code}' http://ALLOWED.test:8000/)" = "403"

        # Without the proxy there is no route out of the sandbox, even to the
        # local server's address.
        if curl --noproxy '*' -fsS --max-time 5 http://allowed.test:8000/ >/dev/null 2>&1; then
          echo "direct network access unexpectedly succeeded" >&2
          exit 1
        fi
      '';
      command = "network-filter-check";
      enableNetwork = true;
      networkFilter.patterns = ["allowed.test" "*.allowed.test"];
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("http-target.service")
    machine.wait_for_open_port(8000)
    machine.succeed("su - alice -c 'harness'")
  '';
}
