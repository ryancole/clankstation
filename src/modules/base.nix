# Core system settings shared by every Clankstation host.
{ pkgs, ... }:
{
  system.stateVersion = "26.05";

  # Latest stable kernel (design: principle 2).
  boot.kernelPackages = pkgs.linuxPackages_latest;

  nix = {
    settings.experimental-features = [
      "nix-command"
      "flakes"
    ];
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
    optimise.automatic = true;
  };

  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # One admin login for the OS phase. The household account belongs to the
  # service layer. The installer writes the SSH key to ~admin/.ssh/authorized_keys.
  users.users.admin = {
    isNormalUser = true;
    # Fixed, so the installer can write ~admin/.ssh before first boot.
    uid = 1000;
    description = "Clankstation admin";
    extraGroups = [ "wheel" ];
  };

  # Trusted box on a home LAN (design: section 1).
  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = with pkgs; [
    git
    htop
    tmux
  ];
}
