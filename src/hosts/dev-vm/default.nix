# Dev VM for local testing. Build and run with:
#   nix build ./src#nixosConfigurations.dev-vm.config.system.build.devVm
#   ./result/bin/clank-dev-vm            # --reset wipes the persistent data disk
#
# It boots from disks formatted with the real disko layout (two-disk: boot
# disk + XFS data disk). The root disk is a fresh overlay on every run. The
# data disk (/var/lib/clankstation: home volumes and sign-ins, projects,
# tasks, Docker images) persists in $CLANK_DEV_STATE (default
# ~/.local/share/clankstation-dev) across runs and rebuilds.
#
# These settings apply only to the VM, never to the appliance itself.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  vm = config.virtualisation.vmVariantWithDisko;
in
{
  clankstation.storage.dataDisk = "/dev/vdb";

  # The web service (S1, no login yet): dev VM only. From the WSL side:
  # http://localhost:8080 (also from Windows, through WSL's localhost
  # forwarding).
  clankstation.web = {
    enable = true;
    address = "0.0.0.0";
    openFirewall = true;
  };

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
        {
          from = "host";
          host.port = 8080;
          guest.port = 8080;
        }
      ];
    };

    # Test-only credentials for the dev VM (user: admin, password: admin).
    users.users.admin.initialPassword = "admin";
    services.openssh.settings.PasswordAuthentication = lib.mkForce true;
  };

  # Like disko's vmWithDisko, but the data disk is kept between runs. The
  # drive paths ("$tmp"/<disk>.qcow2) come from disko's VM variant.
  system.build.devVm = pkgs.writeShellScriptBin "clank-dev-vm" ''
    set -euo pipefail
    state="''${CLANK_DEV_STATE:-$HOME/.local/share/clankstation-dev}"
    images=${vm.system.build.diskoImages}
    mkdir -p "$state"

    if [ "''${1:-}" = --reset ]; then
      rm -f "$state/data.qcow2"
      shift
    fi
    if [ ! -e "$state/data.qcow2" ]; then
      echo "clank-dev-vm: creating persistent data disk at $state/data.qcow2"
      ${pkgs.qemu}/bin/qemu-img convert -O qcow2 "$images/data.qcow2" "$state/data.qcow2"
    fi

    tmp=$(${pkgs.coreutils}/bin/mktemp -d)
    export tmp
    trap 'rm -rf "$tmp"' EXIT
    ${pkgs.qemu}/bin/qemu-img create -q -f qcow2 -b "$images/main.qcow2" -F qcow2 "$tmp/main.qcow2"
    ln -s "$state/data.qcow2" "$tmp/data.qcow2"

    ${vm.system.build.vm}/bin/run-clankstation-vm "$@"
  '';
}
