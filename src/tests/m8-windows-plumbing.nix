# M8 plumbing: everything around a Windows base image build except Windows
# itself (no Windows ISO or network in VM tests; the real build runs on the
# box).
#   - libvirtd, swtpm and the `clank` NAT network are up; Docker no longer
#     drops forwarded traffic
#   - the data partition grows to fill an enlarged disk
#   - `clankctl windows build-base` (dry run) writes a valid answer file, an
#     answer-file CD with the virtio drivers, and a domain libvirt accepts
#   - that domain starts (UEFI + TPM 2.0) and its serial log is readable
{ self, pkgs }:
pkgs.testers.runNixOSTest {
  name = "m8-windows-plumbing";

  nodes.clankstation =
    { lib, pkgs, ... }:
    {
      imports = [
        self.nixosModules.default
        ../hosts/clankstation
      ];
      disko.enableConfig = false;
      virtualisation = {
        memorySize = 3072;
        diskSize = 8192;
      };
      systemd.timers.clankstation-image-linux-default.enable = lib.mkForce false;
      environment.systemPackages = with pkgs; [
        cdrkit
        gptfdisk
        libxml2
      ];
    };

  testScript = ''
    vm = "/var/lib/clankstation/vm"

    clankstation.wait_for_unit("libvirtd.service")
    clankstation.wait_for_unit("clankstation-libvirt-network.service")
    clankstation.wait_for_unit("docker.service")

    # --- network ------------------------------------------------------------
    clankstation.succeed("virsh -c qemu:///system net-info clank | grep -q 'Active: *yes'")
    clankstation.succeed("ip -4 addr show clankbr0 | grep -q 192.168.250.1/24")
    clankstation.succeed("iptables -S FORWARD | head -n 1 | grep -qx -- '-P FORWARD ACCEPT'")

    # --- what Windows 11 needs from the host --------------------------------
    caps = clankstation.succeed("virsh -c qemu:///system domcapabilities --machine q35")
    assert "<value>efi</value>" in caps, caps
    assert "<value>emulator</value>" in caps, caps   # swtpm TPM backend

    # --- data partition grows to fill its disk -----------------------------------
    clankstation.succeed(
        "truncate -s 2G /tmp/disk.img",
        "losetup -P /dev/loop5 /tmp/disk.img",
        "sgdisk -n 1:0:+512M /dev/loop5",
        "partx -u /dev/loop5 || true",
        "mkfs.xfs -q /dev/loop5p1",
        "mkdir -p /mnt/grow && mount /dev/loop5p1 /mnt/grow",
    )
    before = int(clankstation.succeed("df --output=size -B1M /mnt/grow | tail -n 1"))
    clankstation.succeed("clankstation-grow-data /mnt/grow")
    after = int(clankstation.succeed("df --output=size -B1M /mnt/grow | tail -n 1"))
    assert before < 600 and after > 1800, (before, after)
    clankstation.succeed("clankstation-grow-data /mnt/grow")   # idempotent
    clankstation.succeed("umount /mnt/grow && losetup -d /dev/loop5")

    # --- build-base, dry run ------------------------------------------------------
    clankstation.succeed(
        "mkdir -p /tmp/fakeiso && echo not-windows > /tmp/fakeiso/readme.txt",
        "genisoimage -quiet -o /tmp/win.iso /tmp/fakeiso",
        f"install -o clankstation -g clankstation -m 0644 /tmp/win.iso {vm}/iso/win.iso",
    )
    clankstation.fail("clankctl windows build-base demo --iso missing.iso")
    clankstation.fail("clankctl windows build-base demo --iso win.iso --edition 'Windows 11 Mystery'")
    clankstation.succeed(
        "CLANK_WINDOWS_DRY_RUN=1 clankctl windows build-base demo --iso win.iso --memory 512 --cpus 1"
    )
    b = f"{vm}/build/demo"
    clankstation.succeed(f"xmllint --noout {b}/answer/Autounattend.xml")
    clankstation.fail(f"grep -q '@[A-Z_]*@' {b}/answer/Autounattend.xml {b}/domain.xml")
    unattend = clankstation.succeed(f"cat {b}/answer/Autounattend.xml")
    assert "<Value>Windows 11 Pro</Value>" in unattend, unattend
    assert "VK7JG-NPHTM-C97JM-9MPGT-3V66T" in unattend          # generic key: installs unactivated
    assert "PreventDeviceEncryption" in unattend
    password = clankstation.succeed(f"cat {b}/password").strip()
    assert password.startswith("Clank-") and password in unattend
    clankstation.succeed(f"test \"$(stat -c %a {b}/password)\" = 600")

    files = clankstation.succeed(f"isoinfo -J -f -i {b}/answer.iso")
    for f in ["/Autounattend.xml", "/setup.ps1", "/config.json", "/virtio-win-guest-tools.exe",
              "/drivers/viostor/viostor.inf", "/drivers/NetKVM/netkvm.inf"]:
        assert f.lower() in files.lower(), (f, files)

    # libvirt accepts the domain, and it boots firmware with a TPM.
    clankstation.succeed(
        f"virsh -c qemu:///system define --validate {b}/domain.xml",
        "virsh -c qemu:///system undefine --nvram clank-build-demo",
    )
    clankstation.succeed(f"virsh -c qemu:///system create {b}/domain.xml")
    clankstation.wait_until_succeeds("pgrep -f 'swtpm socket'", timeout=60)
    clankstation.succeed("test \"$(virsh -c qemu:///system domstate clank-build-demo)\" = running")
    clankstation.succeed(f"sudo -u clankstation cat {b}/serial.log")
    clankstation.succeed("virsh -c qemu:///system destroy clank-build-demo")

    # Base image bookkeeping.
    out = clankstation.succeed("clankctl windows list")
    assert "NAME" in out, out
    clankstation.succeed("clankctl windows remove demo")
    clankstation.fail(f"test -e {b}")
  '';
}
