# The service layer's web service, clank-web (design section 8): the app,
# its API and actions through clankctl.
#
# S5 (design section 3, "Login", "Joining Tailscale", "Where the app is
# served"): Tailscale runs on the box. The app is served over HTTPS on the
# box's *.ts.net name, only to devices on the tailnet (their Tailscale
# identity is the login); plain HTTP on the LAN (port 80,
# http://clankstation.local) serves only the first-run page that joins
# Tailscale.
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
    enable = lib.mkEnableOption "the Clankstation web service (clank-web) and Tailscale";
    devListen = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "0.0.0.0:8080";
      description = ''
        Also serve the app over plain HTTP with NO login on this address.
        For the dev VM only, where it's forwarded to localhost in WSL.
      '';
    };
    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra clank-web flags (tests use -tls-cert/-tls-key).";
    };
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/clank-web { };
      defaultText = lib.literalExpression "pkgs.callPackage ../pkgs/clank-web { }";
      description = "The clank-web package.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.tailscale = {
      enable = true;
      # Direct connections between devices (UDP 41641) instead of relays.
      openFirewall = true;
      # clank-web fetches the box's ts.net certificate from tailscaled...
      permitCertUid = toString config.clankstation.serviceUser.uid;
      # ...and, as Tailscale's operator, can start Tailscale's own sign-in
      # from the first-run page.
      extraSetFlags = [ "--operator=clankstation" ];
    };

    systemd.services.clankstation-web = {
      description = "Clankstation web service";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "docker.service"
        "tailscaled.service"
      ];
      wants = [ "tailscaled.service" ];
      unitConfig.RequiresMountsFor = [ "/var/lib/clankstation" ];
      serviceConfig = {
        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe cfg.package)
            "-https"
            ":443"
            "-setup"
            ":80"
            "-tailscale-socket"
            "/run/tailscale/tailscaled.sock"
            "-data"
            "/var/lib/clankstation"
            "-docker"
            "/run/docker.sock"
            "-clankctl"
            (lib.getExe config.clankstation.clankctl.package)
          ]
          ++ lib.optionals (cfg.devListen != null) [
            "-listen"
            cfg.devListen
          ]
          ++ cfg.extraArgs
        );
        # The service user owns the task files and runs clankctl for every
        # change (as itself, so clankctl needs no sudo); docker group
        # membership (service-user.nix) lets it see and start task containers.
        User = "clankstation";
        Group = "clankstation";
        # Ports 80 and 443 without running as root.
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
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

    networking.firewall = {
      # The first-run page, on the LAN.
      allowedTCPPorts = [ 80 ];
      # The app, on the tailnet only.
      interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = [ 443 ];
    };
  };
}
