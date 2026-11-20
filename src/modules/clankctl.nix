# clankctl, the OS-phase admin CLI (design: section 5.8).
{ config, pkgs, ... }:
{
  environment.systemPackages = [
    (pkgs.callPackage ../pkgs/clankctl {
      docker = config.virtualisation.docker.package;
      dataRoot = "/var/lib/clankstation";
      inherit (config.clankstation.serviceUser) uid gid;
      image = "clankstation/linux-default:latest";
    })
  ];
}
