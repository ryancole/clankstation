# M1: install the appliance onto blank disks with its disko layout, boot it,
# and check the filesystems and the data tree. One test per layout.
{
  self,
  pkgs,
  disko,
}:
let
  inherit (pkgs) lib;

  dataDirs = [
    "projects"
    "tasks"
    "users"
    "vm/base"
    "vm/overlays"
    "vm/tools"
    "vm/iso"
    "cache"
  ];

  checks = ''
    machine.succeed("findmnt -no FSTYPE /boot | grep -qx vfat")
    machine.succeed("findmnt -no FSTYPE / | grep -qx ext4")
    machine.succeed("findmnt -no FSTYPE /var/lib/clankstation | grep -qx xfs")

    info = machine.succeed("xfs_info /var/lib/clankstation")
    assert "reflink=1" in info, info
    assert "ftype=1" in info, info
    machine.succeed("test \"$(xfs_admin -l $(findmnt -no SOURCE /var/lib/clankstation))\" = 'label = \"clank-data\"'")

    for d in ${builtins.toJSON dataDirs}:
        machine.succeed(f"test -d /var/lib/clankstation/{d}")

    # Reflink copies work on the data disk.
    machine.succeed(
        "dd if=/dev/urandom of=/var/lib/clankstation/cache/a bs=1M count=16",
        "cp --reflink=always /var/lib/clankstation/cache/a /var/lib/clankstation/cache/b",
        "cmp /var/lib/clankstation/cache/a /var/lib/clankstation/cache/b",
    )
  '';

  # disko's test helper: formats the disks from our layout inside an
  # installer VM, installs the system, then reboots into it.
  mkTest =
    name: storage: extraTestScript:
    let
      host = self.nixosConfigurations.clankstation.extendModules {
        modules = [
          {
            clankstation.storage = storage;
            # Keep the installed closure small enough for 4 GiB test disks.
            hardware.enableRedistributableFirmware = lib.mkForce false;
          }
        ];
      };
    in
    disko.lib.testLib.makeDiskoTest {
      inherit pkgs name;
      inherit (host) extendModules;
      disko-config = {
        disko.devices = host.config.disko.devices;
      };
      # Workaround: disko v1.13.0 adds the rebooted VM with
      # driver.machines.append(), but in the nixos-26.05 driver `machines` is
      # a property returning a fresh list, so cleanup never sees the VM and
      # the build hangs. Fixed on disko master (driver.machines_qemu.append);
      # remove this once we move to a disko release newer than v1.13.0.
      extraTestScript = checks + extraTestScript + ''
        machine.shutdown()
      '';
    };
in
{
  m1-storage-two-disk = mkTest "m1-storage-two-disk" { dataDisk = "/dev/vdb"; } ''
    root_disk = machine.succeed("lsblk -no PKNAME $(findmnt -no SOURCE /)").strip()
    data_disk = machine.succeed("lsblk -no PKNAME $(findmnt -no SOURCE /var/lib/clankstation)").strip()
    assert root_disk != data_disk, (root_disk, data_disk)
  '';

  m1-storage-one-disk =
    mkTest "m1-storage-one-disk"
      {
        espSize = "256M";
        rootSize = "3G";
      }
      ''
        root_disk = machine.succeed("lsblk -no PKNAME $(findmnt -no SOURCE /)").strip()
        data_disk = machine.succeed("lsblk -no PKNAME $(findmnt -no SOURCE /var/lib/clankstation)").strip()
        assert root_disk == data_disk, (root_disk, data_disk)
      '';
}
