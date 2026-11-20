# Dev VM for local testing. Build and run with:
#   nix build ./src#nixosConfigurations.dev-vm.config.system.build.vmWithDisko
#   ./result/bin/disko-vm
# The VM boots from disks formatted with the real disko layout (two-disk:
# boot disk + XFS data disk). These settings apply only to the VM, never to
# the appliance itself.
{ lib, ... }:
{
  clankstation.storage.dataDisk = "/dev/vdb";

  virtualisation.vmVariantWithDisko = {
    disko.devices.disk = {
      main.imageSize = "16G";
      data.imageSize = "20G";
    };

    virtualisation = {
      memorySize = 4096;
      cores = 4;
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
