# The `clankstation` service user. It owns project mirrors, task worktrees and
# per-user harness volumes on the host. Task containers run as `agent` with
# the same uid/gid, so files in bind-mounted worktrees keep one owner on both
# sides.
{ config, lib, ... }:
let
  cfg = config.clankstation.serviceUser;
in
{
  options.clankstation.serviceUser = {
    uid = lib.mkOption {
      type = lib.types.int;
      default = 2000;
      description = "uid of the host `clankstation` user and the container `agent` user.";
    };
    gid = lib.mkOption {
      type = lib.types.int;
      default = 2000;
      description = "gid of the host `clankstation` group and the container `agent` group.";
    };
  };

  config = {
    users.groups.clankstation.gid = cfg.gid;
    users.users.clankstation = {
      isSystemUser = true;
      inherit (cfg) uid;
      group = "clankstation";
      home = "/var/lib/clankstation";
      createHome = false;
      extraGroups = [ "docker" ];
    };
  };
}
