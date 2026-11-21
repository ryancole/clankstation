# The appliance on real x86_64 hardware.
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  # Disk drivers the initrd needs beyond NixOS's defaults: Hyper-V's synthetic
  # SCSI (Gen 2 VMs), so Clankstation also installs and boots in Hyper-V.
  boot.initrd.availableKernelModules = [ "hv_storvsc" ];

  hardware = {
    enableRedistributableFirmware = true;
    cpu.intel.updateMicrocode = true;
    cpu.amd.updateMicrocode = true;
  };

  # Disk paths are only used when the installer formats the disks. It points
  # these fixed names at the disks you choose, so the prebuilt system and
  # disko script on the ISO work for any machine. After install, filesystems
  # are mounted by partition label. The one-disk variant sets dataDisk = null.
  clankstation.storage = {
    bootDisk = lib.mkDefault "/dev/clank-boot";
    dataDisk = lib.mkDefault "/dev/clank-data";
  };
}
