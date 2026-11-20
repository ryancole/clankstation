# M2: Docker runs with its data-root on the XFS data disk, and a container
# running as the agent uid can read and write a bind-mounted worktree that
# the host's clankstation user owns.
#
# VM tests have no network, so this uses a digest-pinned ubuntu:26.04 instead
# of building the full default image. The full image build (apt over the
# network) is checked in the dev VM.
{ self, pkgs }:
let
  ubuntu = pkgs.dockerTools.pullImage (import ../images/linux-default/base-image.nix);
in
pkgs.testers.runNixOSTest {
  name = "m2-docker";

  nodes.clankstation =
    { lib, ... }:
    {
      imports = [
        self.nixosModules.default
        ../hosts/clankstation
      ];
      disko.enableConfig = false;

      # Stand-in for the data disk: a blank disk formatted as XFS on first boot.
      virtualisation = {
        memorySize = 2048;
        emptyDiskImages = [ 4096 ];
        fileSystems."/var/lib/clankstation" = {
          device = "/dev/vdb";
          fsType = "xfs";
          autoFormat = true;
        };
      };

      # No network in the test, so the image build can't run.
      systemd.timers.clankstation-image-linux-default.enable = lib.mkForce false;
    };

  testScript = ''
    clankstation.wait_for_unit("docker.service")

    clankstation.succeed("test \"$(docker info --format '{{.DockerRootDir}}')\" = /var/lib/clankstation/docker")
    clankstation.succeed("test \"$(docker info --format '{{.Driver}}')\" = overlay2")
    clankstation.succeed("test \"$(findmnt -no FSTYPE -T /var/lib/clankstation/docker)\" = xfs")

    # Data tree ownership.
    clankstation.succeed("test \"$(stat -c %U:%G /var/lib/clankstation/tasks)\" = clankstation:clankstation")
    clankstation.succeed("test \"$(stat -c %u /var/lib/clankstation/tasks)\" = 2000")

    clankstation.succeed("docker load < ${ubuntu}")

    # A worktree owned by the host service user, bind-mounted into a container
    # running as uid/gid 2000 (the default image's `agent`).
    clankstation.succeed(
        "install -d -o clankstation -g clankstation /var/lib/clankstation/tasks/t1/worktree",
        "sudo -u clankstation sh -c 'echo hello > /var/lib/clankstation/tasks/t1/worktree/README'",
    )
    out = clankstation.succeed(
        "docker run --rm --user 2000:2000"
        " -v /var/lib/clankstation/tasks/t1/worktree:/workspace -w /workspace"
        " ubuntu:26.04 sh -c 'cat README && echo from-container > out.txt && grep -q 26.04 /etc/os-release && echo os-ok'"
    )
    assert "hello" in out and "os-ok" in out, out
    clankstation.succeed("test \"$(stat -c %U /var/lib/clankstation/tasks/t1/worktree/out.txt)\" = clankstation")
    clankstation.succeed("grep -qx from-container /var/lib/clankstation/tasks/t1/worktree/out.txt")

    # The service user can drive Docker (it is in the docker group).
    clankstation.succeed("sudo -u clankstation docker ps")

    # The image build unit is in place (its script lives in a separate store file).
    start = clankstation.succeed("systemctl show -P ExecStart clankstation-image-linux-default.service")
    script = start.split("path=")[1].split(" ")[0]
    clankstation.succeed(f"grep -q 'docker build' {script}")
  '';
}
