# build-vm settings for local testing. These apply only to the VM variant
# (config.system.build.vm), never to the appliance itself.
{ lib, ... }:
{
  virtualisation.vmVariant = {
    virtualisation = {
      memorySize = 4096;
      cores = 4;
      diskSize = 20 * 1024;
      graphics = false;
      # SSH from the WSL side: ssh -p 2222 admin@localhost
      forwardPorts = [
        {
          from = "host";
          host.port = 2222;
          guest.port = 22;
        }
      ];
    };

    # Test-only credentials for the dev VM (user: admin, password: admin).
    users.users.admin.initialPassword = "admin";
    services.openssh.settings.PasswordAuthentication = lib.mkForce true;
  };
}
