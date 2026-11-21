# M7 (installer ISO): the installer installs Clankstation offline onto blank disks, and the
# installed system boots (UEFI, systemd-boot) and takes the admin's SSH key.
#
# The installer VM runs `clankstation-install` with the same module the ISO
# uses. Its targets are the appliance configurations plus NixOS test
# instrumentation, so the test driver can talk to the installed system. The
# second VM boots from the installer VM's two disks with UEFI firmware (no
# boot entries: it falls back to EFI/BOOT/BOOTX64.EFI, like a moved disk).
{ self, pkgs }:
let
  inherit (pkgs) lib;

  testable =
    config:
    config.extendModules {
      modules = [
        (
          { modulesPath, ... }:
          {
            imports = [
              (modulesPath + "/testing/test-instrumentation.nix")
              (modulesPath + "/profiles/qemu-guest.nix")
            ];
            # Keep the closure small for the test disks.
            hardware.enableRedistributableFirmware = lib.mkForce false;
          }
        )
      ];
    };

  target = name: {
    system = (testable self.nixosConfigurations.${name}).config.system.build.toplevel;
    disko = (testable self.nixosConfigurations.${name}).config.system.build.destroyFormatMount;
  };

  qemu-common = import "${pkgs.path}/nixos/lib/qemu-common.nix" {
    inherit lib;
    inherit (pkgs) stdenv;
  };
in
pkgs.testers.runNixOSTest {
  name = "m7-installer";

  nodes.installer = {
    imports = [ ../installer ];
    clankstation.installer = {
      twoDisk = target "clankstation";
      oneDisk = target "clankstation-one-disk";
    };
    virtualisation = {
      useEFIBoot = true;
      memorySize = 3072;
      # vdb: OS disk, vdc: data disk
      emptyDiskImages = [
        12288
        4096
      ];
    };
    environment.systemPackages = [ pkgs.openssh ];
    nix.settings.substituters = lib.mkForce [ ];
  };

  testScript = ''
    import shlex

    installer.start()
    installer.wait_for_unit("multi-user.target")

    # Refuses to erase disks without --yes when nobody can confirm.
    installer.fail("clankstation-install --boot-disk /dev/vdb --data-disk /dev/vdc --ssh-key-file /dev/null < /dev/null")
    installer.fail("clankstation-install --boot-disk /dev/vdb --data-disk /dev/vdb --yes < /dev/null")

    installer.succeed("ssh-keygen -q -t ed25519 -N ''' -C admin-test -f /root/key")
    private_key = installer.succeed("cat /root/key")
    installer.succeed(
        "clankstation-install --boot-disk /dev/vdb --data-disk /dev/vdc"
        " --ssh-key-file /root/key.pub --yes --no-reboot < /dev/null"
    )
    installer.shutdown()

    # Boot the installed disks on a fresh UEFI machine.
    start_command = shlex.split("${qemu-common.qemuBinary pkgs.qemu_test}") + [
        "-m", "2048",
        "-drive", f"file={installer.state_dir}/empty0.qcow2,id=drive1,if=none,index=1,werror=report",
        "-device", "virtio-blk-pci,drive=drive1,bootindex=1",
        "-drive", f"file={installer.state_dir}/empty1.qcow2,id=drive2,if=none,index=2,werror=report",
        "-device", "virtio-blk-pci,drive=drive2",
        "-drive", "if=pflash,format=raw,unit=0,readonly=on,file=${pkgs.OVMF.firmware}",
        "-drive", "if=pflash,format=raw,unit=1,readonly=on,file=${pkgs.OVMF.variables}",
    ]
    box = create_machine(start_command=" ".join(start_command), name="box")
    driver.machines_qemu.append(box)
    box.start()
    box.wait_for_unit("multi-user.target")

    box.succeed("test \"$(hostname)\" = clankstation")
    box.succeed("test \"$(findmnt -no FSTYPE /)\" = ext4")
    box.succeed("test \"$(findmnt -no FSTYPE /var/lib/clankstation)\" = xfs")
    box.succeed("test \"$(lsblk -no PKNAME $(findmnt -no SOURCE /var/lib/clankstation))\" = vdb")
    box.succeed("test -d /var/lib/clankstation/projects")
    box.succeed("test -f /boot/EFI/BOOT/BOOTX64.EFI")
    box.wait_for_unit("docker.service")
    box.wait_for_unit("sshd.service")
    box.succeed("command -v clankctl")

    # The admin can log in with the installed key, and has sudo.
    box.succeed(f"install -m 600 /dev/stdin /root/key <<'EOF'\n{private_key}EOF")
    box.succeed(
        "ssh -i /root/key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
        " admin@localhost 'sudo -n true && test \"$(stat -c %U ~/.ssh/authorized_keys)\" = admin'"
    )
    # ...but not with a password.
    box.fail(
        "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
        " -o BatchMode=yes -o PreferredAuthentications=password admin@localhost true"
    )
    box.shutdown()
  '';
}
