# Disk layout (disko) and the Clankstation data tree (design: section 5.3).
#
#   boot disk: ESP (vfat) + root (ext4)
#   data:      XFS at /var/lib/clankstation, either on its own disk
#              (dataDisk set) or as the last partition of the boot disk.
#
# Filesystems are mounted by GPT partition label, so the device paths below
# only matter when disko formats the disks (at install time).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.clankstation.storage;
  dataRoot = "/var/lib/clankstation";

  # clankstation-grow-data <mountpoint>: grow the partition behind an XFS
  # mount to the end of its disk, then the filesystem to the partition.
  growData = pkgs.writeShellApplication {
    name = "clankstation-grow-data";
    runtimeInputs = with pkgs; [
      cloud-utils
      coreutils
      gawk
      gnused
      gptfdisk
      util-linux
      xfsprogs
    ];
    text = ''
      mnt="$1"
      part=$(findmnt -no SOURCE "$mnt")
      part=$(readlink -f "$part")
      name=$(basename "$part")
      if [ ! -e "/sys/class/block/$name/partition" ]; then
        echo "$mnt is on $part, not a partition; growing the filesystem only"
        xfs_growfs "$mnt" >/dev/null
        exit 0
      fi
      disk="/dev/$(lsblk -no PKNAME "$part" | head -n 1)"
      number=$(cat "/sys/class/block/$name/partition")
      # growpart exits 1 with NOCHANGE when the partition already fills the disk.
      out=$(growpart "$disk" "$number" 2>&1) || case "$out" in
        *NOCHANGE*) ;;
        *) echo "$out" >&2; exit 1 ;;
      esac
      echo "$out"
      xfs_growfs "$mnt" | tail -n 1
      df -h "$mnt" | tail -n 1
    '';
  };

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

    # The data tree, owned by the `clankstation` service user
    # (modules/service-user.nix). libvirt's QEMU runs as root, so it can read
    # the VM images too.
    systemd.tmpfiles.settings."10-clankstation" = lib.genAttrs
      (map (d: "${dataRoot}/${d}") [
        "projects"
        "tasks"
        "users"
        "cache"
        "vm"
        "vm/base"
        "vm/build"
        "vm/overlays"
        "vm/tools"
        "vm/iso"
      ])
      (_: {
        d = {
          mode = "0755";
          user = "clankstation";
          group = "clankstation";
        };
      });

    # Grow the data partition and its XFS filesystem to fill the disk, on
    # every boot. Covers a virtual disk that was enlarged (Hyper-V, cloud
    # volumes) and is a no-op otherwise.
    environment.systemPackages = [ growData ];
    systemd.services.clankstation-grow-data = {
      description = "Grow ${dataRoot} to fill its disk";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      unitConfig.RequiresMountsFor = [ dataRoot ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe growData} ${dataRoot}";
      };
    };
  };
}
