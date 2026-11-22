# S1: the read-only web service. A task started with `clankctl run` shows up
# in the API while it works, its events stream live over SSE, and when it
# ends its summary, question and changed files are there.
#
# Same stand-ins as m4-task (no network in VM tests): a small Nix-built task
# image and a stub `claude` printing stream-json shaped like Claude Code's.
# The real run is checked in the dev VM.
{ self, pkgs }:
let
  # The appliance never enables the service before login exists (S5).
  appliance = self.nixosConfigurations.clankstation.config;

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
    echo '{"type":"system","subtype":"init","session_id":"stub-session-1"}'
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Looking at the form."},{"type":"tool_use","id":"t1","name":"TodoWrite","input":{"todos":[{"content":"Find the form","status":"completed"},{"content":"Send mail","status":"in_progress"}]}}]}}'
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"sleep 20","description":"Run the tests"}}]}}'
    sleep 20
    echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":false,"content":"ok"}]}}'
    echo 'hello' > contact.txt
    echo '{"type":"result","subtype":"success","is_error":false,"result":"Added contact.txt.\n\nShould it go to info@ or to you?","session_id":"stub-session-1","total_cost_usd":0.01,"duration_ms":20000}'
  '';
in
assert !appliance.clankstation.web.enable;
pkgs.testers.runNixOSTest {
  name = "s1-web";

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

    def api(path):
        return json.loads(clankstation.succeed(f"curl -sf http://127.0.0.1:8080{path}"))

    clankstation.wait_for_unit("docker.service")
    clankstation.wait_for_unit("clankstation-web.service")
    clankstation.wait_for_open_port(8080)
    assert clankstation.succeed("systemctl show -p User --value clankstation-web").strip() == "clankstation"

    # The app itself, and an empty task list.
    assert "<!doctype html>" in clankstation.succeed("curl -sf http://127.0.0.1:8080/").lower()
    assert api("/api/tasks") == []
    clankstation.fail("curl -sf http://127.0.0.1:8080/api/tasks/..%2F..%2Fetc")

    # Set up as in m4-task.
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

    out = clankstation.succeed("su admin -c \"clankctl run demo 'Make the form send mail'\" 2>/dev/null")
    task = out.strip().splitlines()[0]
    assert re.fullmatch(r"t-\d{8}-\d{6}-[0-9a-f]{4}", task), out

    # While it works: running, with the current step as the card's line.
    clankstation.wait_until_succeeds(
        "curl -sf http://127.0.0.1:8080/api/tasks | grep -q '\"activity\":\"Run the tests\"'", timeout=60
    )
    [card] = api("/api/tasks")
    assert card["id"] == task and card["state"] == "running", card
    assert card["title"] == "Make the form send mail", card

    # The live stream: state first, then the translated events.
    sse = clankstation.succeed(
        f"curl -sN --max-time 3 http://127.0.0.1:8080/api/tasks/{task}/events || true"
    )
    assert '"type":"state","state":"running"' in sse, sse
    assert '"type":"plan"' in sse and '"label":"Run the tests"' in sse, sse
    assert re.search(r"^id: 3$", sse, re.M), sse
    # Resuming after line 2 skips lines 1-2.
    resumed = clankstation.succeed(
        f"curl -sN --max-time 2 -H 'Last-Event-ID: 2' http://127.0.0.1:8080/api/tasks/{task}/events || true"
    )
    assert '"type":"turn"' not in resumed and '"type":"plan"' not in resumed, resumed
    assert '"label":"Run the tests"' in resumed, resumed

    # When it ends: the summary asks a question, so it needs an answer.
    clankstation.wait_until_succeeds(f"test -f /var/lib/clankstation/tasks/{task}/status.json", timeout=120)
    detail = api(f"/api/tasks/{task}")
    assert detail["state"] == "needs_input", detail
    assert detail["question"] == "Should it go to info@ or to you?", detail
    assert [f["path"] for f in detail["files"]] == ["contact.txt"], detail["files"]
    assert detail["files"][0]["status"] == "added", detail["files"]
    assert detail["turns"][0]["kind"] == "run", detail["turns"]
    changes = api(f"/api/tasks/{task}/changes")
    assert "+hello" in changes[0]["patch"], changes
  '';
}
