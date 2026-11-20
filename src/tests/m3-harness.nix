# M3: per-user home volume plumbing for harnesses.
#
# VM tests have no network, so the official installer can't run here.
# Instead a stub `claude` in the home volume stands in for Claude Code: it
# records "signed in" in the home volume the way the real harness keeps its
# token. The test checks that sign-in done in one container is visible in a
# fresh one, and that clankctl gets ownership and sudo right. The real
# install and /login are checked in the dev VM.
{ self, pkgs }:
let
  ubuntu = pkgs.dockerTools.pullImage (import ../images/linux-default/base-image.nix);
  stubClaude = pkgs.writeText "claude-stub" ''
    #!/bin/sh
    case "$1 $2" in
      "--version "*) echo "0.0.0-stub (Claude Code)" ;;
      "auth login") echo signed-in > "$HOME/.stub-auth"; echo "Login successful" ;;
      "auth status")
        if [ -f "$HOME/.stub-auth" ]; then echo "Logged in (stub)"; else echo "Not logged in"; exit 1; fi ;;
    esac
  '';
in
pkgs.testers.runNixOSTest {
  name = "m3-harness";

  nodes.clankstation =
    { lib, ... }:
    {
      imports = [
        self.nixosModules.default
        ../hosts/clankstation
      ];
      disko.enableConfig = false;
      virtualisation.memorySize = 2048;
      systemd.timers.clankstation-image-linux-default.enable = lib.mkForce false;
    };

  testScript = ''
    clankstation.wait_for_unit("docker.service")
    # Stand-in for the default image: plain ubuntu works because clankctl
    # passes --user, HOME and PATH explicitly.
    clankstation.succeed(
        "docker load < ${ubuntu}",
        "docker tag ubuntu:26.04 clankstation/linux-default:latest",
    )

    # Before opt-in: no harness.
    out = clankstation.succeed("clankctl harness status")
    assert "not installed" in out, out

    home = "/var/lib/clankstation/users/default/home"
    clankstation.succeed(f"test \"$(stat -c '%u %a' {home})\" = '2000 700'")
    clankstation.succeed(f"test -f {home}/.bashrc")  # dotfiles copied from /etc/skel

    # "Install" the stub through clankctl (stdin passes into the container).
    clankstation.succeed(
        "clankctl shell sh -c 'mkdir -p ~/.local/bin && cat > ~/.local/bin/claude && chmod +x ~/.local/bin/claude' < ${stubClaude}"
    )
    out = clankstation.succeed("clankctl harness status")
    assert "0.0.0-stub" in out and "Not logged in" in out, out

    # Sign in once, in one container...
    clankstation.succeed("clankctl login claude")
    # ...and a fresh container sees it. Run as the admin user to cover the
    # sudo re-exec to the clankstation user.
    out = clankstation.succeed("su admin -c 'clankctl harness status'")
    assert "Logged in (stub)" in out, out

    # Files in the volume belong to the service user; no containers are left.
    clankstation.succeed(f"test \"$(stat -c %u {home}/.stub-auth)\" = 2000")
    clankstation.succeed("test -z \"$(docker ps -aq)\"")

    # Bad user names are rejected before touching the filesystem.
    clankstation.fail("CLANK_USER=../etc clankctl harness status")
  '';
}
