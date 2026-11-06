{
  self,
  pkgs,
  ...
}:
pkgs.testers.nixosTest {
  name = "nixos-harness-one-shot";

  nodes.machine = {pkgs, ...}: {
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

    services.harness-jail = {
      enable = true;
      daemon = false;
      package = pkgs.writeShellScriptBin "sandbox-check" ''
        set -eu
        test -r /nix/store
        test ! -e /nix/var/nix/daemon-socket/socket
        test "$FILE_VALUE" = "value with spaces and 'quotes'"
        test "$EXPLICIT" = "from-environment"
        test "$HOME" = "/home/alice/.local/state/harness-jail"
        test -w "$HOME"
        test ! -e /home/alice/secret
        test "$(cat /var/lib/harness-test/env)" = ""
      '';
      command = "sandbox-check";
      environmentFile = "/var/lib/harness-test/env";
      readWritePaths = ["/var/lib/harness-test"];
      environment.EXPLICIT = "from-environment";
    };
  };

  testScript = ''
    machine.start()
    machine.fail("systemctl status harness-jail.service")
    machine.fail("id harness-jail")

    machine.succeed("mkdir -p /var/lib/harness-test /home/alice")
    machine.succeed("echo 'top secret' > /home/alice/secret")
    machine.succeed("cat > /var/lib/harness-test/env <<'EOF'\nFILE_VALUE=\"value with spaces and 'quotes'\"\nEOF")
    machine.succeed("chmod 0644 /var/lib/harness-test/env")

    machine.succeed("su - alice -c 'harness'")
  '';
}
