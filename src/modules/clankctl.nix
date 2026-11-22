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
  };
}
