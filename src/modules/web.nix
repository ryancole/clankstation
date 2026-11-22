# The service layer's web service, clank-web (design section 8, S1: read-only).
# Off by default: until login lands (S5) it is enabled on the dev VM only.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.clankstation.web;
in
{
  options.clankstation.web = {
    enable = lib.mkEnableOption "the Clankstation web service (clank-web)";
    address = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address clank-web listens on.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port clank-web listens on.";
    };
    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the port on the LAN.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/clank-web { };
      defaultText = lib.literalExpression "pkgs.callPackage ../pkgs/clank-web { }";
      description = "The clank-web package.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.clankstation-web = {
      description = "Clankstation web service";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "docker.service"
      ];
      unitConfig.RequiresMountsFor = [ "/var/lib/clankstation" ];
      serviceConfig = {
        ExecStart = lib.escapeShellArgs [
          (lib.getExe cfg.package)
          "-listen"
          "${cfg.address}:${toString cfg.port}"
          "-data"
          "/var/lib/clankstation"
          "-docker"
          "/run/docker.sock"
        ];
        # The service user owns the task files; docker group membership
        # (service-user.nix) lets it ask Docker which tasks are running.
        User = "clankstation";
        Group = "clankstation";
        Restart = "on-failure";
        # S1 only reads.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
