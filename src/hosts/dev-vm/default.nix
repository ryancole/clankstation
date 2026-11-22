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

  # The web app with NO login on port 8080, for development: from the WSL
  # side (and Windows, through WSL's localhost forwarding)
  # http://localhost:8080. The first-run page (port 80) is at
  # http://localhost:8081. Once the dev VM has joined a tailnet, the real
  # thing is at https://<name>.ts.net from devices on it.
  clankstation.web.devListen = "0.0.0.0:8080";
  networking.firewall.allowedTCPPorts = [ 8080 ];

  # The root disk is fresh on every run; keep Tailscale's identity on the
  # persistent data disk, so the dev VM stays on its tailnet.
  systemd.tmpfiles.rules = [ "d /var/lib/clankstation/dev-tailscale 0700 root root -" ];
  systemd.services.tailscaled.serviceConfig.BindPaths = [
    "/var/lib/clankstation/dev-tailscale:/var/lib/tailscale"
  ];
  systemd.services.tailscaled.unitConfig.RequiresMountsFor = [ "/var/lib/clankstation" ];

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
        {
          from = "host";
          host.port = 8081;
          guest.port = 80;
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
