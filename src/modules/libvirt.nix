# QEMU/KVM through libvirt for Windows task environments (design: section 5.5).
{ config, pkgs, ... }:
let
  # NAT network for task VMs. The host is 192.168.250.1 on clankbr0.
  network = pkgs.writeText "clank-network.xml" ''
    <network>
      <name>clank</name>
      <forward mode='nat'/>
      <bridge name='clankbr0' stp='on' delay='0'/>
      <ip address='192.168.250.1' netmask='255.255.255.0'>
        <dhcp>
          <range start='192.168.250.100' end='192.168.250.250'/>
        </dhcp>
      </ip>
    </network>
  '';
  virsh = "${config.virtualisation.libvirtd.package}/bin/virsh";
in
{
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      # Windows 11 needs TPM 2.0.
      swtpm.enable = true;
      runAsRoot = true;
      # Leave image and log ownership alone: they belong to the clankstation
      # user, and QEMU runs as root anyway.
      verbatimConfig = ''
        namespaces = []
        dynamic_ownership = 0
      '';
    };
    # Task VMs are started by clankctl, never automatically.
    onBoot = "ignore";
    onShutdown = "shutdown";
  };

  users.users.clankstation.extraGroups = [ "libvirtd" ];
  users.users.admin.extraGroups = [ "libvirtd" ];

  # Docker otherwise sets the FORWARD policy to DROP, which also drops the
  # libvirt VMs' NAT traffic.
  virtualisation.docker.daemon.settings.ip-forward-no-drop = true;

  # The VM network: DHCP and DNS from libvirt's dnsmasq, plus whatever the
  # host serves to task VMs (git, in M9).
  networking.firewall.trustedInterfaces = [ "clankbr0" ];

  systemd.services.clankstation-libvirt-network = {
    description = "libvirt NAT network for Clankstation task VMs";
    after = [ "libvirtd.service" ];
    requires = [ "libvirtd.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if ! ${virsh} -c qemu:///system net-info clank >/dev/null 2>&1; then
        ${virsh} -c qemu:///system net-define ${network}
      fi
      ${virsh} -c qemu:///system net-autostart clank
      if [ "$(${virsh} -c qemu:///system net-info clank | sed -n 's/^Active: *//p')" != yes ]; then
        ${virsh} -c qemu:///system net-start clank
      fi
    '';
  };
}
