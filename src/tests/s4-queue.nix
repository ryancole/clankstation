# S4: the queue. With the default limit of 1, a second task waits in line
# and starts by itself when the first finishes; a waiting task can be taken
# out of line and started later; a reply waits too; raising the limit lets
# two run at once. Driven through the web API and clankctl alike.
#
# Same stand-ins as m4-task (no network in VM tests): a small Nix-built task
# image and a stub `claude` that works for 20 s on prompts with "slow".
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
    prompt="$2"
    echo '{"type":"system","subtype":"init","session_id":"stub-session-1"}'
    printf '%s\n---\n' "$prompt" >> PROMPTS.log
    case "$prompt" in *slow*) sleep 20 ;; esac
    echo '{"type":"result","subtype":"success","is_error":false,"result":"Done.","session_id":"stub-session-1"}'
  '';
in
pkgs.testers.runNixOSTest {
  name = "s4-queue";

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
    import json, re

    base = "http://127.0.0.1:8080"
    tasks = "/var/lib/clankstation/tasks"

    def get(path):
        return json.loads(clankstation.succeed(f"curl -sf {base}{path}"))

    def post(path, body=None):
        data = json.dumps(body or {}).replace("'", "'\\'''")
        out = clankstation.succeed(
            f"curl -sf -X POST -H 'Content-Type: application/json' -d '{data}' {base}{path}"
        )
        return json.loads(out) if out.strip() else None

    def new(prompt):
        return post("/api/tasks", {"project": "demo", "prompt": prompt})["id"]

    def state(task):
        return get(f"/api/tasks/{task}")["state"]

    def wait_state(task, want, timeout=120):
        clankstation.wait_until_succeeds(
            f"curl -sf {base}/api/tasks/{task} | grep -q '\"state\":\"{want}\"'", timeout=timeout
        )

    clankstation.wait_for_unit("docker.service")
    clankstation.wait_for_unit("clankstation-queue.service")
    clankstation.wait_for_unit("clankstation-web.service")
    clankstation.wait_for_open_port(8080)
    clankstation.succeed("docker load < ${testImage}")
    clankstation.succeed(
        "mkdir -p /srv/upstream",
        "cd /srv/upstream && git init -q -b main && echo '# Demo' > README.md"
        " && git add README.md && git -c user.name=t -c user.email=t@example.com commit -qm init",
        "chown -R clankstation:clankstation /srv/upstream",
        "clankctl project add demo /srv/upstream",
        "clankctl shell sh -c 'v=$HOME/.local/share/claude/versions/0.0.0-stub"
        " && mkdir -p ~/.local/bin $(dirname $v) && cat > $v && chmod +x $v"
        " && ln -s $v ~/.local/bin/claude' < ${stubClaude}",
    )
    assert clankstation.succeed("clankctl config").strip() == "max-running 1"

    # --- One at a time: the others wait in line, in order ----------------------
    a = new("slow A")
    wait_state(a, "running")
    b = new("slow B")
    c = new("quick C")
    assert state(b) == "queued" and state(c) == "queued", (state(b), state(c))
    assert get(f"/api/tasks/{b}")["activity"] == "Next in line"
    assert get(f"/api/tasks/{c}")["activity"] == "2nd in line"
    q = clankstation.succeed("clankctl queue")
    assert q.index(b) < q.index(c), q
    # Over SSH too: clankctl run waits in line behind them.
    out = clankstation.succeed("su admin -c \"clankctl run demo 'quick D'\" 2>&1")
    assert "Waiting in line" in out, out
    m = re.search(r"t-\d{8}-\d{6}-[0-9a-f]{4}", out)
    assert m, out
    d = m.group(0)
    assert state(d) == "queued"

    # --- Take C out of line; it never ran ---------------------------------------
    post(f"/api/tasks/{c}/stop")
    assert state(c) == "stopped", state(c)
    clankstation.fail(f"test -e {tasks}/{c}/queued")

    # --- A finishes: B starts by itself, then D; never two at once --------------
    wait_state(a, "done")
    wait_state(b, "running", timeout=30)
    assert state(d) == "queued" and get(f"/api/tasks/{d}")["activity"] == "Next in line"
    assert clankstation.succeed("docker ps -q | wc -l").strip() == "1"
    wait_state(b, "done")
    wait_state(d, "done", timeout=60)

    # --- C starts later from a reply, with its first prompt and the reply --------
    post(f"/api/tasks/{c}/reply", {"prompt": "go now"})
    wait_state(c, "done")
    prompts = clankstation.succeed(f"cat {tasks}/{c}/worktree/PROMPTS.log")
    assert prompts == "quick C\n\ngo now\n---\n", prompts

    # --- A reply waits in line like a new task ------------------------------------
    e = new("slow E")
    wait_state(e, "running")
    post(f"/api/tasks/{a}/reply", {"prompt": "slow again"})
    assert state(a) == "queued", state(a)
    wait_state(e, "done")
    wait_state(a, "running", timeout=30)
    wait_state(a, "done")

    # --- Raise the limit: two at once --------------------------------------------
    clankstation.succeed("clankctl config set max-running 2")
    assert clankstation.succeed("cat /var/lib/clankstation/settings/box.env").strip() == "max_running=2"
    f = new("slow F")
    g = new("slow G")
    wait_state(f, "running")
    wait_state(g, "running")
    assert clankstation.succeed("docker ps -q | wc -l").strip() == "2"
    wait_state(f, "done")
    wait_state(g, "done")
    clankstation.fail("clankctl config set max-running 0")
  '';
}
