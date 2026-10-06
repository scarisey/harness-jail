{
  self,
  pkgs,
  ...
}:
pkgs.testers.nixosTest {
  name = "nixos-headroom";

  nodes.machine = {pkgs, ...}: {
    imports = [
      self.nixosModules.headroom
    ];

    virtualisation = {
      memorySize = 4096;
      cores = 2;
    };

    services.headroom = {
      enable = true;
    };

    environment.systemPackages = [pkgs.curl];
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("headroom.service")
    machine.wait_for_open_port(8787)
    machine.succeed("curl -fsS http://127.0.0.1:8787/livez")
    machine.succeed("headroom --version")
  '';
}
