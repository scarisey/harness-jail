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
      package = pkgs.hello;
      command = "hello";
    };
  };

  testScript = ''
    machine.start()
    machine.fail("systemctl status harness-jail.service")
    machine.succeed("id harness-jail")
    machine.succeed("harness")
  '';
}
