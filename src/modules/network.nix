# Hostname, mDNS (clankstation.local), SSH and firewall.
{
  networking = {
    hostName = "clankstation";
    # systemd-networkd, with useDHCP (the default) giving DHCP on any
    # interface that shows up.
    useNetworkd = true;
    firewall.enable = true;
  };

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };
}
