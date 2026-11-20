# The appliance on real x86_64 hardware.
{ modulesPath, ... }:
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

  # Placeholder until the disko layout lands in M1.
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/clank-root";
      fsType = "ext4";
    };
    "/boot" = {
      device = "/dev/disk/by-label/CLANK-ESP";
      fsType = "vfat";
      options = [ "umask=0077" ];
    };
  };
}
