{
  lib,
  writeShellApplication,
  writeText,
  coreutils,
  docker,
  findutils,
  git,
  gnused,
  jq,
  dataRoot,
  uid,
  gid,
  image,
}:
let
  # Runs inside the task container (with the image's bash, git and jq).
  taskRun = writeText "clank-task-run" (builtins.readFile ./task-run.sh);
in
writeShellApplication {
  name = "clankctl";
  # SC2016: `sh -c '...$HOME...'` is meant to expand inside the container.
  excludeShellChecks = [ "SC2016" ];
  runtimeInputs = [
    coreutils
    docker
    findutils
    git
    gnused
    jq
  ];
  text = ''
    CLANK_DATA=${lib.escapeShellArg dataRoot}
    CLANK_UID=${toString uid}
    CLANK_GID=${toString gid}
    CLANK_IMAGE=${lib.escapeShellArg image}
    CLANK_TASK_RUN=${taskRun}
  ''
  + builtins.readFile ./clankctl.sh;

  passthru = { inherit taskRun; };
}
