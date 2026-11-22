# The box's own screen (S9, design section 8): a read-only status page on
# tty1 in place of the login prompt. It shows how to reach the app (with a QR
# code), what the tasks are doing and what needs attention. The admin login
# stays on the other consoles (Alt+F2).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.clankstation.console;
in
{
  options.clankstation.console.enable = lib.mkEnableOption "the status page on the box's screen (tty1)";

  config = lib.mkIf cfg.enable {
    # Not the login prompt on tty1 (as services.cage does it).
    systemd.services."getty@tty1".enable = false;
    systemd.services."autovt@tty1".enable = false;

    systemd.services.clankstation-console = {
      description = "Clankstation status page on the box's screen";
      wantedBy = [ "multi-user.target" ];
      after = [
        "systemd-user-sessions.service"
        "getty@tty1.service"
        "tailscaled.service"
        "docker.service"
      ];
      conflicts = [ "getty@tty1.service" ];
      unitConfig.ConditionPathExists = "/dev/tty1";
      serviceConfig = {
        ExecStart = lib.escapeShellArgs [
          (lib.getExe config.clankstation.web.package)
          "-console"
          "-qrencode"
          (lib.getExe pkgs.qrencode)
          "-tailscale-socket"
          "/run/tailscale/tailscaled.sock"
          "-data"
          "/var/lib/clankstation"
          "-docker"
          "/run/docker.sock"
        ];
        # Reads what the app reads, as the same user; changes nothing.
        User = "clankstation";
        Group = "clankstation";
        TTYPath = "/dev/tty1";
        TTYReset = true;
        TTYVHangup = true;
        StandardInput = "tty-force";
        StandardOutput = "tty";
        StandardError = "journal";
        Restart = "always";
        RestartSec = 2;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
      };
    };
  };
}
