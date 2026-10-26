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

    services.harness-jail = {
      enable = true;
      daemon = false;
      package = pkgs.writeShellScriptBin "sandbox-check" ''
        set -eu
        test -r /nix/store
        test ! -e /nix/var/nix/daemon-socket/socket
        test "$FILE_VALUE" = "value with spaces and 'quotes'"
        test "$EXPLICIT" = "from-environment"
      '';
      command = "sandbox-check";
      environmentFile = "/run/harness.env";
      environment.EXPLICIT = "from-environment";
    };
  };

  testScript = ''
    machine.start()
    machine.fail("systemctl status harness-jail.service")
    machine.succeed("id harness-jail")
    machine.succeed("cat > /run/harness.env <<'EOF'\nFILE_VALUE=\"value with spaces and 'quotes'\"\nEOF")
    machine.succeed("harness")
  '';
}
