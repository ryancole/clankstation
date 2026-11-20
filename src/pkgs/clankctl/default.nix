{
  lib,
  writeShellApplication,
  coreutils,
  docker,
  dataRoot,
  uid,
  gid,
  image,
}:
writeShellApplication {
  name = "clankctl";
  # SC2016: `sh -c '...$HOME...'` is meant to expand inside the container.
  excludeShellChecks = [ "SC2016" ];
  runtimeInputs = [
    coreutils
    docker
  ];
  text = ''
    CLANK_DATA=${lib.escapeShellArg dataRoot}
    CLANK_UID=${toString uid}
    CLANK_GID=${toString gid}
    CLANK_IMAGE=${lib.escapeShellArg image}
  ''
  + builtins.readFile ./clankctl.sh;
}
