# M4: a prompt runs headless in a container, keeps running after the
# command that started it exits, and leaves a summary and a diff.
#
# VM tests have no network, so:
#   - the task image is a small Nix-built stand-in with what the in-container
#     runner needs (bash, git, jq);
#   - a stub `claude` in the home volume plays the harness. It edits files and
#     prints stream-json events shaped like Claude Code's.
# The real run against Claude Code is checked in the dev VM.
{ self, pkgs }:
let
  testImage = pkgs.dockerTools.buildLayeredImage {
    name = "clankstation/linux-default";
    tag = "latest";
    contents = with pkgs; [
      bashInteractive
      coreutils
      diffutils
      findutils
      git
      gnugrep
      gnused
      jq
      dockerTools.binSh
      dockerTools.usrBinEnv
    ];
    extraCommands = "mkdir -m 1777 tmp";
  };

  stubClaude = pkgs.writeText "claude-stub" ''
    #!/bin/sh
    # Called as: claude -p <prompt> --output-format stream-json ...
    prompt="$2"
    echo '{"type":"system","subtype":"init","session_id":"stub-session-1"}'
    case "$prompt" in
      *slow*) sleep 15 ;;
      *fail*)
        echo '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"stub failure"}'
        exit 1 ;;
    esac
    echo "$prompt" >> NOTES.md
    echo 'new file' > added.txt
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
    echo '{"type":"result","subtype":"success","is_error":false,"result":"Appended the prompt to NOTES.md and added added.txt.","session_id":"stub-session-1"}'
  '';
in
pkgs.testers.runNixOSTest {
  name = "m4-task";

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
    import re

    tasks = "/var/lib/clankstation/tasks"

    clankstation.wait_for_unit("docker.service")
    clankstation.succeed("docker load < ${testImage}")

    # An upstream repo with one commit (in real use: an https or ssh URL).
    clankstation.succeed(
        "mkdir -p /srv/upstream",
        "cd /srv/upstream && git init -q -b main && echo '# Demo' > README.md"
        " && git add README.md && git -c user.name=t -c user.email=t@example.com commit -qm init",
        "chown -R clankstation:clankstation /srv/upstream",
    )

    # Running before the harness is installed fails with a clear message.
    clankstation.succeed("clankctl project add demo /srv/upstream")
    out = clankstation.fail("clankctl run demo 'too early' 2>&1")
    assert "not installed" in out, out

    # Installed the way the native installer does it: ~/.local/bin/claude is a
    # symlink to an absolute in-container path, which doesn't resolve on the host.
    clankstation.succeed(
        "clankctl shell sh -c 'v=$HOME/.local/share/claude/versions/0.0.0-stub"
        " && mkdir -p ~/.local/bin $(dirname $v) && cat > $v && chmod +x $v"
        " && ln -s $v ~/.local/bin/claude' < ${stubClaude}"
    )
    clankstation.fail("test -e /var/lib/clankstation/users/default/home/.local/bin/claude")
    assert "demo" in clankstation.succeed("clankctl project list")

    def run(prompt):
        out = clankstation.succeed(f"su admin -c \"clankctl run demo '{prompt}'\" 2>/dev/null")
        task = out.strip().splitlines()[0]
        assert re.fullmatch(r"t-\d{8}-\d{6}-[0-9a-f]{4}", task), out
        return task

    def wait_done(task):
        clankstation.wait_until_succeeds(f"test -f {tasks}/{task}/status.json", timeout=120)

    # --- A task that succeeds -------------------------------------------------
    t1 = run("add a note")
    wait_done(t1)
    show = clankstation.succeed(f"clankctl show {t1}")
    assert "State:   done" in show, show
    assert "Session: stub-session-1" in show, show
    assert "Appended the prompt to NOTES.md" in show, show
    assert "NOTES.md" in show and "added.txt" in show, show

    diff = clankstation.succeed(f"clankctl diff {t1}")
    assert "+add a note" in diff and "+new file" in diff, diff

    status = clankstation.succeed("clankctl status")
    assert re.search(rf"{t1}\s+done\s+demo\s+add a note", status), status

    # The task works on its own clone and branch; the mirror is untouched.
    # (git as the owning user: git refuses repos owned by someone else.)
    git = "sudo -u clankstation git"
    # Its branch: words from the prompt and the end of the id (S10).
    head = clankstation.succeed(f"sed -n 's/^head=//p' {tasks}/{t1}/task.env").strip()
    assert re.fullmatch(rf"clank/[a-z0-9-]+-{t1[-4:]}", head), head
    clankstation.succeed(f"test \"$({git} -C {tasks}/{t1}/worktree branch --show-current)\" = {head}")
    clankstation.succeed(f"test -z \"$({git} -C /var/lib/clankstation/projects/demo/mirror.git branch --list 'clank/*')\"")
    clankstation.succeed(f"test \"$(stat -c %U {tasks}/{t1}/worktree/added.txt)\" = clankstation")

    # --- A slow task keeps running after `clankctl run` has returned ----------
    t2 = run("slow task")
    assert re.search(rf"{t2}\s+running", clankstation.succeed("clankctl status"))
    clankstation.succeed(f"test -n \"$(docker ps -q --filter label=clankstation.task={t2})\"")
    clankstation.succeed("! pgrep -f '[c]lankctl run'")  # [c]: don't match this shell itself
    wait_done(t2)
    assert "State:   done" in clankstation.succeed(f"clankctl show {t2}")

    # --- A task whose harness fails ------------------------------------------
    t3 = run("please fail")
    wait_done(t3)
    show = clankstation.succeed(f"clankctl show {t3}")
    assert "State:   failed" in show and "stub failure" in show, show

    # Containers are cleaned up; task ids are validated.
    clankstation.succeed("test -z \"$(docker ps -aq)\"")
    clankstation.fail("clankctl show ../../etc")
  '';
}
