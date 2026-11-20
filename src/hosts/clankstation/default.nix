# The appliance on real x86_64 hardware.
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  hardware = {
    enableRedistributableFirmware = true;
    cpu.intel.updateMicrocode = true;
    cpu.amd.updateMicrocode = true;
  };

  # Only used when disko formats the disks. The installer (M9) sets the real
  # disk(s); after install, filesystems are mounted by partition label.
  clankstation.storage.bootDisk = lib.mkDefault "/dev/nvme0n1";
}
