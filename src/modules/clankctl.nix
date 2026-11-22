# clankctl, the OS-phase admin CLI (design: section 5.8).
{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.clankstation.clankctl.package = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    internal = true;
    description = "The clankctl package (used by the cleanup timer).";
  };

  config = {
    clankstation.clankctl.package = pkgs.callPackage ../pkgs/clankctl {
      docker = config.virtualisation.docker.package;
      dataRoot = "/var/lib/clankstation";
      inherit (config.clankstation.serviceUser) uid gid;
      image = "clankstation/linux-default:latest";
    };

    environment.systemPackages = [ config.clankstation.clankctl.package ];

    # Starts tasks waiting in line as slots free up (`clankctl queue run`).
    # The limit is runtime state (`clankctl config set max-running <n>`).
    systemd.services.clankstation-queue = {
      description = "Clankstation task queue";
      wantedBy = [ "multi-user.target" ];
      after = [ "docker.service" ];
      wants = [ "docker.service" ];
      unitConfig.RequiresMountsFor = [ "/var/lib/clankstation" ];
      serviceConfig = {
        ExecStart = "${lib.getExe config.clankstation.clankctl.package} queue run";
        User = "clankstation";
        Group = "clankstation";
        Restart = "always";
        RestartSec = 5;
        # A devcontainer task it started keeps preparing in the background:
        # restarting the queue must not kill it.
        KillMode = "process";
      };
    };
  };
}
