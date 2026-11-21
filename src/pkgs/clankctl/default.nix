{
  lib,
  buildEnv,
  writeShellApplication,
  writeText,
  bashInteractive,
  coreutils,
  devcontainer,
  docker,
  findutils,
  git,
  gnugrep,
  gnused,
  jq,
  util-linux,
  dataRoot,
  uid,
  gid,
  image,
}:
let
  # The runner's own tools inside task containers, reached through the host's
  # /nix/store mounted read-only, so the runner doesn't depend on the image.
  taskTools = buildEnv {
    name = "clank-task-tools";
    paths = [
      bashInteractive
      coreutils
      findutils
      git
      gnugrep
      gnused
      jq
    ];
  };

  taskRun = writeText "clank-task-run" (
    ''
      CLANK_TOOLS=${taskTools}
    ''
    + builtins.readFile ./task-run.sh
  );

  # Extra layer on a project's devcontainer image: the agent user (uid/gid
  # matching the host's clankstation user).
  agentLayer = ../../images/devcontainer-agent;
in
writeShellApplication {
  name = "clankctl";
  # SC2016: `sh -c '...$HOME...'` is meant to expand inside the container.
  excludeShellChecks = [ "SC2016" ];
  runtimeInputs = [
    coreutils
    devcontainer
    docker
    findutils
    git
    gnugrep
    gnused
    jq
    util-linux
  ];
  text = ''
    CLANK_DATA=${lib.escapeShellArg dataRoot}
    CLANK_UID=${toString uid}
    CLANK_GID=${toString gid}
    CLANK_IMAGE=${lib.escapeShellArg image}
    CLANK_TASK_RUN=${taskRun}
    CLANK_BASH=${bashInteractive}/bin/bash
    CLANK_AGENT_LAYER=${agentLayer}
  ''
  + builtins.readFile ./clankctl.sh;

  passthru = { inherit taskRun taskTools; };
}
