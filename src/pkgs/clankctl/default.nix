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
  gawk,
  gh,
  git,
  gnugrep,
  gnused,
  jq,
  util-linux,
  cdrkit,
  libvirt,
  netpbm,
  qemu,
  virtio-win,
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
      gh
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

  # Answer file, setup script and domain template for Windows base images.
  windowsTemplates = ../../images/windows;
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
    gawk
    git
    gnugrep
    gnused
    jq
    util-linux
    cdrkit
    libvirt
    netpbm
    qemu
  ];
  text = ''
    CLANK_DATA=${lib.escapeShellArg dataRoot}
    CLANK_UID=${toString uid}
    CLANK_GID=${toString gid}
    CLANK_IMAGE=${lib.escapeShellArg image}
    CLANK_TASK_RUN=${taskRun}
    CLANK_BASH=${bashInteractive}/bin/bash
    CLANK_GH=${gh}/bin/gh
    CLANK_AGENT_LAYER=${agentLayer}
    CLANK_WINDOWS_TEMPLATES=${windowsTemplates}
    CLANK_VIRTIO_WIN=${virtio-win}
  ''
  + builtins.readFile ./clankctl.sh;

  passthru = { inherit taskRun taskTools; };
}
