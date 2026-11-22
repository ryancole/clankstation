# Cleanup timer (design: section 5.3). Prunes the worktrees (and Windows
# overlays) of tasks that finished more than `retention` ago, and the
# devcontainer images no remaining task uses. Results stay until a task is
# deleted with `clankctl delete`.
{ config, lib, ... }:
let
  cfg = config.clankstation.cleanup;
in
{
  options.clankstation.cleanup = {
    retention = lib.mkOption {
      type = lib.types.str;
      default = "7d";
      description = "How long a finished task keeps its worktree (`clankctl clean --older-than`).";
    };
    dates = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "When the cleanup runs (systemd calendar expression).";
    };
  };

  config = {
    systemd.services.clankstation-clean = {
      description = "Prune old Clankstation task worktrees";
      requires = [ "docker.service" ];
      after = [ "docker.service" ];
      unitConfig.RequiresMountsFor = [ "/var/lib/clankstation" ];
      serviceConfig = {
        Type = "oneshot";
        User = "clankstation";
        Group = "clankstation";
        ExecStart = "${config.clankstation.clankctl.package}/bin/clankctl clean --older-than ${lib.escapeShellArg cfg.retention}";
      };
    };

    systemd.timers.clankstation-clean = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.dates;
        Persistent = true;
        RandomizedDelaySec = "30m";
      };
    };
  };
}
