# S2: everything a household user does day to day, through the web API
# alone: add a project, queue a task, answer its question, stop a task and
# keep it going, and continue a task the box lost mid-turn.
#
# Same stand-ins as m4-task (no network in VM tests): a small Nix-built task
# image and a stub `claude`. The real run is checked in the dev VM.
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

  # Called as: claude -p <prompt> [--resume <session>] --output-format ...
  # Logs each prompt to PROMPTS.log in the worktree. "slow" sleeps; any
  # prompt without "thanks" ends with a question.
  stubClaude = pkgs.writeText "claude-stub" ''
    #!/bin/sh
    prompt="$2"
    echo '{"type":"system","subtype":"init","session_id":"stub-session-1"}'
    printf '%s\n' "$prompt" >> PROMPTS.log
    case "$prompt" in *slow*) sleep 60 ;; esac
    case "$prompt" in
      *thanks*) echo '{"type":"result","subtype":"success","is_error":false,"result":"All done.","session_id":"stub-session-1"}' ;;
      *) echo '{"type":"result","subtype":"success","is_error":false,"result":"Logged it.\n\nAnything else?","session_id":"stub-session-1"}' ;;
    esac
  '';
in
pkgs.testers.runNixOSTest {
  name = "s2-actions";

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
      clankstation.web.enable = true;
      environment.systemPackages = [ pkgs.curl ];
    };

  testScript = ''
    import json

    base = "http://127.0.0.1:8080"
    tasks = "/var/lib/clankstation/tasks"

    def get(path):
        return json.loads(clankstation.succeed(f"curl -sf {base}{path}"))

    def post(path, body=None, origin=base, expect=None):
        data = json.dumps(body or {}).replace("'", "'\\'''")
        out = clankstation.succeed(
            f"curl -s -o /tmp/out -w '%{{http_code}}' -X POST -H 'Content-Type: application/json'"
            f" -H 'Origin: {origin}' -d '{data}' {base}{path}; echo; cat /tmp/out"
        )
        code, _, rest = out.partition("\n")
        if expect is not None:
            assert int(code) == expect, (path, code, rest)
        try:
            body = json.loads(rest) if rest.strip() else None
        except json.JSONDecodeError:
            body = rest  # a plain-text refusal (403)
        return int(code), body

    def state(task):
        return get(f"/api/tasks/{task}")["state"]

    def wait_state(task, want, timeout=120):
        clankstation.wait_until_succeeds(
            f"curl -sf {base}/api/tasks/{task} | grep -q '\"state\":\"{want}\"'", timeout=timeout
        )

    def prompts(task):
        return clankstation.succeed(f"cat {tasks}/{task}/worktree/PROMPTS.log")

    clankstation.wait_for_unit("docker.service")
    clankstation.wait_for_unit("clankstation-web.service")
    clankstation.wait_for_open_port(8080)
    clankstation.succeed("docker load < ${testImage}")
    clankstation.succeed(
        "mkdir -p /srv/upstream",
        "cd /srv/upstream && git init -q -b main && echo '# Demo' > README.md"
        " && git add README.md && git -c user.name=t -c user.email=t@example.com commit -qm init",
        "chown -R clankstation:clankstation /srv/upstream",
        "clankctl shell sh -c 'v=$HOME/.local/share/claude/versions/0.0.0-stub"
        " && mkdir -p ~/.local/bin $(dirname $v) && cat > $v && chmod +x $v"
        " && ln -s $v ~/.local/bin/claude' < ${stubClaude}",
    )

    # --- Projects --------------------------------------------------------------
    assert get("/api/projects") == []
    _, err = post("/api/projects", {"name": "demo", "url": "/srv/nothing-here"}, expect=400)
    assert "could not clone" in err["error"], err
    post("/api/projects", {"name": "demo", "url": "/srv/upstream"}, expect=201)
    _, err = post("/api/projects", {"name": "demo", "url": "/srv/upstream"}, expect=400)
    assert "already exists" in err["error"], err
    assert [p["name"] for p in get("/api/projects")] == ["demo"]

    # Another site's page can't drive the box.
    post("/api/tasks", {"project": "demo", "prompt": "x"}, origin="http://evil.example", expect=403)
    assert get("/api/tasks") == []

    # --- Queue a task and answer its question ----------------------------------
    _, out = post("/api/tasks", {"project": "demo", "prompt": "Log 'this' prompt"}, expect=201)
    t1 = out["id"]
    wait_state(t1, "needs_input")
    assert get(f"/api/tasks/{t1}")["question"] == "Anything else?"
    post(f"/api/tasks/{t1}/reply", {"prompt": "No, thanks"}, expect=204)
    wait_state(t1, "done")
    d = get(f"/api/tasks/{t1}")
    assert [t["kind"] for t in d["turns"]] == ["run", "resume"], d["turns"]
    assert d["summary"] == "All done.", d
    assert prompts(t1) == "Log 'this' prompt\nNo, thanks\n", prompts(t1)
    assert clankstation.succeed(f"stat -c %U {tasks}/{t1}/worktree/PROMPTS.log").strip() == "clankstation"

    # --- Stop a task, then keep going -----------------------------------------
    _, out = post("/api/tasks", {"project": "demo", "prompt": "a slow one"}, expect=201)
    t2 = out["id"]
    wait_state(t2, "running")
    _, err = post(f"/api/tasks/{t2}/reply", {"prompt": "hurry"}, expect=400)
    assert "still running" in err["error"], err
    post(f"/api/tasks/{t2}/stop", expect=204)
    assert state(t2) == "stopped", state(t2)
    post(f"/api/tasks/{t2}/reply", {"prompt": "keep going, thanks"}, expect=204)
    wait_state(t2, "done")
    _, err = post(f"/api/tasks/{t2}/stop", expect=400)
    assert "not running" in err["error"], err

    # --- A task the box lost mid-turn can still continue ------------------------
    _, out = post("/api/tasks", {"project": "demo", "prompt": "slow again"}, expect=201)
    t3 = out["id"]
    wait_state(t3, "running")
    clankstation.wait_until_succeeds(f"grep -q init {tasks}/{t3}/events.jsonl")
    clankstation.succeed(f"docker kill clank-{t3}")  # no chance to write status.json
    wait_state(t3, "lost")
    post(f"/api/tasks/{t3}/reply", {"prompt": "keep going, thanks"}, expect=204)
    wait_state(t3, "done")
    assert "--- " in clankstation.succeed(f"cat {tasks}/{t3}/prompts.log")
    assert prompts(t3).endswith("keep going, thanks\n"), prompts(t3)
  '';
}
