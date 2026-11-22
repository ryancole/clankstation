# S3: the browser terminal for Settings: sign in through a terminal (the code
# typed isn't logged) and Claude's status. Taking over a task was part of S3
# and is out of the app since S4 (design section 3).
#
# Same stand-ins as m4-task (no network in VM tests): a small Nix-built task
# image and a stub `claude` with `auth login`, `auth status` and
# `--version`. A real sign-in is checked in the dev VM.
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
    case "$1" in
      --version) echo "9.9.9 (Claude Code)"; exit 0 ;;
      auth)
        case "$2" in
          status) echo '{"loggedIn": true, "authMethod": "claude.ai", "email": "someone@example.com", "subscriptionType": "pro"}' ;;
          login)
            echo "Open the sign-in link, then paste the code here:"
            IFS= read -r code
            echo "Login successful."
            ;;
        esac
        exit 0 ;;
      -p)
        echo '{"type":"system","subtype":"init","session_id":"stub-session-1"}'
        sleep 120
        exit 0 ;;
    esac
    # Interactive: claude --resume <session> --permission-mode ...
    [ -t 0 ] && echo "STUB INTERACTIVE $2 on a terminal"
    while IFS= read -r line; do
      case "$line" in
        */exit*) echo "taken over" > TAKEN-OVER.txt; echo "Goodbye"; exit 0 ;;
        *) echo "you said: $line" ;;
      esac
    done
  '';

  termclient = pkgs.writers.writePython3Bin "termclient" {
    libraries = [ pkgs.python3Packages.websockets ];
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./termclient.py);
in
pkgs.testers.runNixOSTest {
  name = "s3-terminal";

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
      clankstation.web.devListen = "127.0.0.1:8080";
      environment.systemPackages = [
        pkgs.curl
        termclient
      ];
    };

  testScript = ''
    import json, shlex

    base = "http://127.0.0.1:8080"
    ws = "ws://127.0.0.1:8080"
    tasks = "/var/lib/clankstation/tasks"

    def get(path):
        return json.loads(clankstation.succeed(f"curl -sf {base}{path}"))

    def term(path, *steps):
        return clankstation.succeed(
            f"termclient {ws}{path} " + " ".join(shlex.quote(s) for s in steps)
        )

    def wait_state(task, want):
        clankstation.wait_until_succeeds(
            f"curl -sf {base}/api/tasks/{task} | grep -q '\"state\":\"{want}\"'", timeout=120
        )

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

    # --- Settings: Claude's status, without the account's email ---------------
    st = clankstation.succeed(f"curl -sf {base}/api/claude")
    assert json.loads(st) == {"installed": True, "version": "9.9.9", "signed_in": True,
                              "method": "claude.ai", "plan": "pro"}, st
    assert "example.com" not in st

    # --- Sign in through the terminal; the code isn't logged -------------------
    out = term("/api/terminal/login", "e:paste the code here", "s:SECRET-CODE-123\\r",
               "e:Login successful", "x:0")
    assert "Login successful" in out, out
    clankstation.fail("journalctl -u clankstation-web | grep -q SECRET-CODE-123")

    # Only the terminals the app offers: taking over a task is out of it for now.
    clankstation.fail(f"termclient {ws}/api/terminal/shell q")
    clankstation.fail(f"termclient '{ws}/api/terminal/attach?task=t-20990101-000000-ffff' q")
  '';
}
