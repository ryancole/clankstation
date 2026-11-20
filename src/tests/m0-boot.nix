# M0: the appliance boots, runs SSH, and is reachable as clankstation.local
# from another machine on the LAN.
{ self, pkgs }:
pkgs.testers.runNixOSTest {
  name = "m0-boot";

  nodes = {
    clankstation = {
      imports = [
        self.nixosModules.default
        ../hosts/clankstation
      ];
      # The test VM brings its own root disk; the disko layout is covered by m1-storage.
      disko.enableConfig = false;
    };

    client =
      { pkgs, ... }:
      {
        services.avahi = {
          enable = true;
          nssmdns4 = true;
        };
        environment.systemPackages = [ pkgs.netcat ];
      };
  };

  testScript = ''
    start_all()

    clankstation.wait_for_unit("multi-user.target")
    clankstation.wait_for_unit("sshd.service")
    clankstation.wait_for_unit("avahi-daemon.service")
    clankstation.wait_for_open_port(22)
    clankstation.succeed("test \"$(hostname)\" = clankstation")
    print(clankstation.succeed("uname -r"))

    client.wait_for_unit("avahi-daemon.service")
    client.wait_until_succeeds("getent hosts clankstation.local", timeout=60)
    client.succeed("nc -z -w 5 clankstation.local 22")
  '';
}
