# Disk layout (disko) and the Clankstation data tree (design: section 5.3).
#
#   boot disk: ESP (vfat) + root (ext4)
#   data:      XFS at /var/lib/clankstation, either on its own disk
#              (dataDisk set) or as the last partition of the boot disk.
#
# Filesystems are mounted by GPT partition label, so the device paths below
# only matter when disko formats the disks (at install time).
{ config, lib, ... }:
let
  cfg = config.clankstation.storage;
  dataRoot = "/var/lib/clankstation";

  esp = {
    type = "EF00";
    size = cfg.espSize;
    content = {
      type = "filesystem";
      format = "vfat";
      extraArgs = [
        "-n"
        "CLANK-ESP"
      ];
      mountpoint = "/boot";
      mountOptions = [ "umask=0077" ];
    };
  };

  root = size: {
    inherit size;
    content = {
      type = "filesystem";
      format = "ext4";
      extraArgs = [
        "-L"
        "clank-root"
      ];
      mountpoint = "/";
    };
  };

  # XFS: reflinks make copies of base images and SDKs nearly free. Docker's
  # overlay2 needs ftype=1. Both are mkfs.xfs defaults; set explicitly anyway.
  data = {
    size = "100%";
    content = {
      type = "filesystem";
      format = "xfs";
      extraArgs = [
        "-L"
        "clank-data"
        "-m"
        "reflink=1"
        "-n"
        "ftype=1"
      ];
      mountpoint = dataRoot;
      mountOptions = [ "noatime" ];
    };
  };

  twoDisks = cfg.dataDisk != null;
in
{
  options.clankstation.storage = {
    bootDisk = lib.mkOption {
      type = lib.types.str;
      example = "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S7XXXXXXXXXXXXX";
      description = "Disk that holds the ESP and the root filesystem.";
    };

    dataDisk = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Separate disk for /var/lib/clankstation. When null, the data
        partition is the rest of the boot disk.
      '';
    };

    espSize = lib.mkOption {
      type = lib.types.str;
      default = "1G";
      description = "Size of the EFI system partition.";
    };

    rootSize = lib.mkOption {
      type = lib.types.str;
      default = "64G";
      description = ''
        Size of the root partition when there is no separate data disk.
        With a data disk, root fills the boot disk.
      '';
    };
  };

  config = {
    disko.devices.disk = {
      main = {
        type = "disk";
        device = cfg.bootDisk;
        content = {
          type = "gpt";
          partitions = {
            ESP = esp;
            root = root (if twoDisks then "100%" else cfg.rootSize);
          }
          // lib.optionalAttrs (!twoDisks) { inherit data; };
        };
      };
    }
    // lib.optionalAttrs twoDisks {
      data = {
        type = "disk";
        device = cfg.dataDisk;
        content = {
          type = "gpt";
          partitions = { inherit data; };
        };
      };
    };

    boot.supportedFilesystems = [ "xfs" ];

    # The data tree. Work data belongs to the `clankstation` service user
    # (modules/service-user.nix); VM images stay root-owned for libvirt.
    systemd.tmpfiles.settings."10-clankstation" =
      let
        dir = owner: {
          d = {
            mode = "0755";
            user = owner;
            group = owner;
          };
        };
        under = owner: dirs: lib.genAttrs (map (d: "${dataRoot}/${d}") dirs) (_: dir owner);
      in
      under "clankstation" [
        "projects"
        "tasks"
        "users"
        "cache"
      ]
      // under "root" [
        "vm"
        "vm/base"
        "vm/overlays"
        "vm/tools"
        "vm/iso"
      ];
  };
}
