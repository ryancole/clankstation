# The installer ISO. Write it to a USB stick, boot the box from it (UEFI),
# and run `sudo clankstation-install`.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
{
  imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];

  # Latest stable kernel for the widest hardware support (design: principle 2).
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.supportedFilesystems.zfs = lib.mkForce false;
  # Hyper-V Gen 2 VMs attach the DVD and disks through synthetic SCSI.
  boot.initrd.availableKernelModules = [ "hv_storvsc" ];

  image.baseName = lib.mkForce "clankstation-installer-${config.system.nixos.label}";
  isoImage = {
    volumeID = "CLANKSTATION";
    # Fast to build, still small enough for a USB stick.
    squashfsCompression = "zstd -Xcompression-level 6";
  };

  networking.hostName = "clankstation-installer";

  services.getty.helpLine = lib.mkForce ''

    Clankstation installer. To install (this erases the disks you choose):

        sudo clankstation-install

  '';

  system.stateVersion = "26.05";
}
