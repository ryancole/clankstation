# Docker for Linux task environments (design: section 5.4), and the default
# task image built from src/images/linux-default.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  dataRoot = "/var/lib/clankstation";
  docker = config.virtualisation.docker.package;
  inherit (config.clankstation.serviceUser) uid gid;

  imageSrc = ../images/linux-default;
  # The tag changes whenever the Dockerfile or the agent uid/gid change, which
  # triggers a rebuild.
  imageTag = lib.substring 0 12 (builtins.hashString "sha256" "${imageSrc}:${toString uid}:${toString gid}");
  imageName = "clankstation/linux-default";
in
{
  virtualisation.docker = {
    enable = true;
    # Package left at the nixpkgs default (docker_29 in 26.05).
    storageDriver = "overlay2";
    daemon.settings = {
      data-root = "${dataRoot}/docker";
      # live-restore is on by default: task containers keep running while
      # dockerd restarts (for example during nixos-rebuild switch).
      log-driver = "json-file";
      log-opts = {
        max-size = "50m";
        max-file = "3";
      };
    };
    autoPrune = {
      enable = true;
      dates = "weekly";
      # Dangling images and stopped containers only; tagged images are kept.
      flags = [ "--filter=until=168h" ];
    };
  };

  systemd.services.docker.unitConfig.RequiresMountsFor = [ dataRoot ];

  users.users.admin.extraGroups = [ "docker" ];

  # Build the default task image once per Dockerfile version. Needs network
  # (base image and apt packages), so it runs from a timer instead of holding
  # up boot, and retries until it succeeds.
  systemd.services.clankstation-image-linux-default = {
    description = "Build the default Linux task image";
    requires = [ "docker.service" ];
    after = [
      "docker.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    path = [ docker ];
    serviceConfig = {
      Type = "oneshot";
      Restart = "on-failure";
      RestartSec = "60s";
    };
    script = ''
      if docker image inspect ${imageName}:${imageTag} >/dev/null 2>&1; then
        echo "${imageName}:${imageTag} is up to date"
      else
        docker build --pull \
          --build-arg AGENT_UID=${toString uid} \
          --build-arg AGENT_GID=${toString gid} \
          --tag ${imageName}:${imageTag} \
          ${imageSrc}
      fi
      docker tag ${imageName}:${imageTag} ${imageName}:latest
    '';
  };

  systemd.timers.clankstation-image-linux-default = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "1d";
    };
  };
}
