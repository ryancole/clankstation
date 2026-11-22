# The service layer's web service, clank-web (design section 8): the app,
# its API (S1) and actions through clankctl (S2).
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
          "-clankctl"
          (lib.getExe config.clankstation.clankctl.package)
        ];
        # The service user owns the task files and runs clankctl for every
        # change (as itself, so clankctl needs no sudo); docker group
        # membership (service-user.nix) lets it see and start task containers.
        User = "clankstation";
        Group = "clankstation";
        Restart = "on-failure";
        # A devcontainer task keeps preparing in a background clankctl after
        # the request returns: restarting the service must not kill it.
        KillMode = "process";
        ProtectSystem = "strict";
        ReadWritePaths = [ "/var/lib/clankstation" ];
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
          "AF_NETLINK"
        ];
        LockPersonality = true;
        # No MemoryDenyWriteExecute: clankctl runs the devcontainers CLI
        # (Node.js, which needs a JIT).
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
