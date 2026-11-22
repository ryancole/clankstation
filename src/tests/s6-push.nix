# S6: push notifications. A stand-in push service on another node plays the
# phone's browser vendor: it hands out a subscription, receives what the box
# sends, and decrypts it the way a phone would. Checks: the test button, a
# notification when a task finishes and when Claude has a question, none for
# a task you stopped, and the box's keys and subscriptions kept on the data
# disk. A real phone is checked on the box.
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
    case "$prompt" in *slow*) sleep 30 ;; *) sleep 5 ;; esac
    case "$prompt" in
      *ask*) echo '{"type":"result","subtype":"success","is_error":false,"result":"Started.\n\nWhich colour should it be?","session_id":"stub-session-1"}' ;;
      *) echo '{"type":"result","subtype":"success","is_error":false,"result":"Made the change. All good.","session_id":"stub-session-1"}' ;;
    esac
  '';

  pushsvc = pkgs.writers.writePython3Bin "pushsvc" {
    libraries = [ pkgs.python3Packages.cryptography ];
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./pushsvc.py);
in
pkgs.testers.runNixOSTest {
  name = "s6-push";

  nodes = {
    pushsvc = {
      networking.firewall.allowedTCPPorts = [ 9000 ];
      systemd.services.pushsvc = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pushsvc}/bin/pushsvc";
      };
    };

    clankstation =
      { lib, ... }:
      {
        imports = [
          self.nixosModules.default
          ../hosts/clankstation
        ];
        disko.enableConfig = false;
        virtualisation.memorySize = 2048;
        systemd.timers.clankstation-image-linux-default.enable = lib.mkForce false;
        clankstation.web.devListen = "127.0.0.1:8080";
        environment.systemPackages = [ pkgs.curl ];
      };
  };

  testScript = ''
    import json

    base = "http://127.0.0.1:8080"

    def post(path, body):
        data = json.dumps(body).replace("'", "'\\'''")
        return clankstation.succeed(
            f"curl -sf -X POST -H 'Content-Type: application/json' -d '{data}' {base}{path}"
        )

    def got():
        out = pushsvc.succeed("cat /tmp/got.jsonl 2>/dev/null || true")
        return [json.loads(l) for l in out.splitlines() if l.strip()]

    def wait_got(n):
        pushsvc.wait_until_succeeds(f"test $(wc -l < /tmp/got.jsonl) -ge {n}", timeout=120)
        return got()

    start_all()
    pushsvc.wait_for_open_port(9000)
    pushsvc.wait_for_file("/tmp/sub.json")
    clankstation.wait_for_unit("docker.service")
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

    # --- The phone signs up ------------------------------------------------------
    key = json.loads(clankstation.succeed(f"curl -sf {base}/api/push/key"))["key"]
    assert len(key) > 80, key
    sub = json.loads(pushsvc.succeed("cat /tmp/sub.json"))
    post("/api/push/subscribe", sub)
    push_dir = "/var/lib/clankstation/settings/push"
    assert clankstation.succeed(f"stat -c '%a %U' {push_dir}/vapid.json").strip() == "600 clankstation"
    assert sub["endpoint"] in clankstation.succeed(f"cat {push_dir}/subscriptions.json")

    # --- The test button ---------------------------------------------------------
    post("/api/push/test", {"endpoint": sub["endpoint"]})
    assert wait_got(1)[-1]["title"] == "Clankstation"

    # --- A task finishes ---------------------------------------------------------
    t1 = json.loads(post("/api/tasks", {"project": "demo", "prompt": "Make the change"}))["id"]
    n = wait_got(2)[-1]
    assert n["title"] == "Done: Make the change", n
    assert n["body"] == "Made the change.", n  # the summary's first sentence
    assert n["url"] == f"/#/task/{t1}" and n["tag"] == t1, n

    # --- Claude has a question -----------------------------------------------------
    t2 = json.loads(post("/api/tasks", {"project": "demo", "prompt": "ask me something"}))["id"]
    n = wait_got(3)[-1]
    assert n["title"] == "Claude has a question" and n["body"] == "Which colour should it be?", n

    # --- A task you stop: nothing ---------------------------------------------------
    t3 = json.loads(post("/api/tasks", {"project": "demo", "prompt": "slow one"}))["id"]
    clankstation.wait_until_succeeds(f"curl -sf {base}/api/tasks/{t3} | grep -q '\"state\":\"running\"'")
    post(f"/api/tasks/{t3}/stop", {})
    clankstation.wait_until_succeeds(f"curl -sf {base}/api/tasks/{t3} | grep -q '\"state\":\"stopped\"'")
    clankstation.sleep(8)
    assert len(got()) == 3, got()

    # --- A reply that finishes: notified again ------------------------------------
    post(f"/api/tasks/{t2}/reply", {"prompt": "blue"})
    n = wait_got(4)[-1]
    assert n["title"] == "Done: ask me something", n

    # --- The phone signs off --------------------------------------------------------
    post("/api/push/unsubscribe", {"endpoint": sub["endpoint"]})
    assert sub["endpoint"] not in clankstation.succeed(f"cat {push_dir}/subscriptions.json")
  '';
}
