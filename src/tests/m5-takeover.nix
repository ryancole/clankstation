# M5: keep going and take over.
#   - resume: continue a finished task's session with a new headless turn
#   - logs: follow what a running task is doing
#   - shell --task: look inside a task's environment
#   - stop: stop a running task, keeping its results
#   - attach: take over in an interactive harness session (stopping a running
#     headless turn first), then hand the task back
#
# Offline, like m4-task: a Nix-built stand-in image and a stub `claude`
# installed the way the native installer does it. The stub handles -p
# (headless), --resume, and no -p (interactive).
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
    prompt= sid= interactive=1
    while [ $# -gt 0 ]; do
      case "$1" in
        -p) prompt="$2"; interactive=0; shift 2 ;;
        --resume) sid="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ "$interactive" = 1 ]; then
      echo "interactive stub session $sid"
      echo "interactive edit" >> NOTES.md
      exit 0
    fi
    session="''${sid:-stub-session-1}"
    echo "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$session\"}"
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Looking at NOTES.md"},{"type":"tool_use","name":"Edit","input":{"file_path":"NOTES.md"}}]}}'
    case "$prompt" in
      # Backgrounded so SIGTERM ends this shell straight away.
      *slow*) sleep 120 & wait $! ;;
    esac
    echo "$prompt" >> NOTES.md
    if [ -n "$sid" ]; then
      result="Resumed $sid: $prompt"
    else
      result="Started: $prompt"
      echo new > added.txt
    fi
    echo "{\"type\":\"result\",\"is_error\":false,\"result\":\"$result\",\"session_id\":\"$session\"}"
  '';
in
pkgs.testers.runNixOSTest {
  name = "m5-takeover";

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
    clankstation.succeed(
        "docker load < ${testImage}",
        "mkdir -p /srv/upstream",
        "cd /srv/upstream && git init -q -b main && echo '# Demo' > README.md"
        " && git add README.md && git -c user.name=t -c user.email=t@example.com commit -qm init",
        "chown -R clankstation:clankstation /srv/upstream",
        "clankctl project add demo /srv/upstream",
        "clankctl shell sh -c 'v=$HOME/.local/share/claude/versions/0.0.0-stub"
        " && mkdir -p ~/.local/bin $(dirname $v) && cat > $v && chmod +x $v"
        " && ln -s $v ~/.local/bin/claude' < ${stubClaude}",
    )

    def run(prompt):
        out = clankstation.succeed(f"clankctl run demo '{prompt}' 2>/dev/null")
        return out.strip().splitlines()[0]

    def state(task):
        show = clankstation.succeed(f"clankctl show {task}")
        m = re.search(r"State:\s+(\S+)", show)
        assert m is not None, show
        return m.group(1)

    def wait_finished(task):
        clankstation.wait_until_succeeds(f"test -f {tasks}/{task}/status.json", timeout=120)

    # --- resume a finished task ----------------------------------------------
    t1 = run("add a note")
    wait_finished(t1)
    assert state(t1) == "done"

    clankstation.succeed(f"clankctl resume {t1} 'and another'")
    wait_finished(t1)
    show = clankstation.succeed(f"clankctl show {t1}")
    assert "State:   done" in show, show
    assert "Session: stub-session-1" in show, show
    assert "Resumed stub-session-1: and another" in show, show
    diff = clankstation.succeed(f"clankctl diff {t1}")
    assert "+add a note" in diff and "+and another" in diff and "+new" in diff, diff
    clankstation.succeed(f"test $(grep -c '^--- ' {tasks}/{t1}/prompts.log) -eq 2")

    logs = clankstation.succeed(f"clankctl logs {t1}")
    assert "[session stub-session-1]" in logs, logs
    assert "● Looking at NOTES.md" in logs and "→ Edit" in logs, logs
    assert "✓ done: Resumed stub-session-1: and another" in logs, logs

    # --- a running task: refuse resume, look inside, follow, stop -------------
    t2 = run("slow task")
    clankstation.wait_until_succeeds(f"grep -q init {tasks}/{t2}/events.jsonl")
    assert state(t2) == "running"
    clankstation.fail(f"clankctl resume {t2} 'more'")
    assert "slow task" in clankstation.succeed(f"clankctl shell --task {t2} cat /clank/prompt.txt")

    clankstation.succeed(f"(clankctl logs -f {t2} > /tmp/follow.log 2>&1 &)")
    clankstation.wait_until_succeeds("grep -q 'session stub-session-1' /tmp/follow.log")

    out = clankstation.succeed(f"clankctl stop {t2}")
    assert f"{t2}: stopped" in out, out
    assert state(t2) == "stopped"
    # `logs -f` ends on its own once the task's container is gone.
    clankstation.wait_until_succeeds("! pgrep -f '[l]ogs -f'", timeout=30)
    # A stopped task can be continued like any other.
    clankstation.succeed(f"clankctl resume {t2} 'finish up'")
    wait_finished(t2)
    assert state(t2) == "done"

    # --- attach to a finished task --------------------------------------------
    out = clankstation.succeed(f"clankctl attach {t1} < /dev/null 2>&1")
    assert "interactive stub session stub-session-1" in out, out
    assert "+interactive edit" in clankstation.succeed(f"clankctl diff {t1}")
    assert state(t1) == "done"
    clankstation.succeed(f"grep -q '\"mode\": *\"interactive\"' {tasks}/{t1}/status.json")

    # --- attach to a running task: needs --yes without a terminal --------------
    t3 = run("slow again")
    clankstation.wait_until_succeeds(f"grep -q init {tasks}/{t3}/events.jsonl")
    clankstation.fail(f"clankctl attach {t3} < /dev/null")
    assert state(t3) == "running"
    out = clankstation.succeed(f"clankctl attach --yes {t3} < /dev/null 2>&1")
    assert "interactive stub session stub-session-1" in out, out
    assert state(t3) == "done"

    # A side shell on a finished task doesn't make it look running.
    clankstation.succeed(f"clankctl shell --task {t1} test -f added.txt")
    assert state(t1) == "done"
    clankstation.succeed("test -z \"$(docker ps -aq)\"")
  '';
}
