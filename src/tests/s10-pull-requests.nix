# S10: pull requests (design 8.2). A task on a project with pull requests on
# gets a readable branch; after each turn the runner commits what Claude left,
# pushes the branch and opens a draft pull request on the first push, then
# updates it. Not signed in to GitHub: the turn still ends well and says why
# nothing was pushed. A merged pull request gets a new one for new work.
#
# No GitHub in VM tests: a second machine serves the "upstream" over
# git://, and a stub `gh` in the user's environment stands in for GitHub's
# CLI (the runner uses a gh installed there first). The stub `claude` works
# like m4-task's. The real flow is checked on the HyperV VM.
{ self, pkgs }:
let
  testImage = pkgs.dockerTools.buildLayeredImage {
    name = "clankstation/linux-default";
    tag = "latest";
    contents = with pkgs; [
      bashInteractive
      coreutils
      git
      dockerTools.binSh
      dockerTools.usrBinEnv
    ];
    extraCommands = "mkdir -m 1777 tmp";
  };

  # Turn 1 leaves a new file uncommitted; turn 2 commits by itself; later
  # turns leave changes uncommitted again.
  stubClaude = pkgs.writeText "claude-stub" ''
    #!/bin/sh
    n=$(cat "$HOME/.stub-turn" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "$HOME/.stub-turn"
    echo '{"type":"system","subtype":"init","session_id":"stub-session-1"}'
    case "$n" in
      1) echo hello > contact.txt ;;
      2) echo more >> contact.txt
         git add -A
         git -c user.name=Claude -c user.email=claude@example.com commit -qm "Add more to the form" ;;
      *) echo "turn $n" >> contact.txt ;;
    esac
    echo '{"type":"result","subtype":"success","is_error":false,"result":"Turn '"$n"' done.","session_id":"stub-session-1"}'
  '';

  # GitHub's CLI, as far as the runner uses it. State in ~/.gh-stub.
  stubGh = pkgs.writeText "gh-stub" ''
    #!/bin/sh
    s=$HOME/.gh-stub
    mkdir -p "$s"
    echo "gh $*" >> "$s/calls"
    case "$1 $2" in
      "api user")
        [ ! -e "$s/signed-out" ] || { echo "not logged in" >&2; exit 4; }
        echo "alice 42" ;;
      "auth git-credential") exit 0 ;;
      "pr create")
        shift 2
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --head) head=$2; shift ;;
            --base) base=$2; shift ;;
            --title) title=$2; shift ;;
            --body-file) cp "$2" "$s/body"; shift ;;
            --draft) draft=true ;;
          esac
          shift
        done
        n=$(( $(cat "$s/count" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$s/count"
        echo "$n base=$base draft=$draft title=$title" >> "$s/created"
        url="https://github.example/alice/upstream/pull/$n"
        printf '{"number":%s,"url":"%s","state":"OPEN","isDraft":true}\n' "$n" "$url" > "$s/pr-$n.json"
        ln -sf "pr-$n.json" "$s/pr-$(echo "$head" | tr / _).json"
        echo "$url" ;;
      "pr edit") echo "$3" >> "$s/edited"; cp "$5" "$s/body" ;;
      # By number or by branch.
      "pr view") cat "$s/pr-$(echo "$3" | tr / _).json" ;;
      *) echo "gh stub: $*" >&2; exit 1 ;;
    esac
  '';
in
pkgs.testers.runNixOSTest {
  name = "s10-pull-requests";

  nodes = {
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
        clankstation.web.enable = true;
        clankstation.web.devListen = "127.0.0.1:8080";
        environment.systemPackages = [
          pkgs.curl
          pkgs.jq
        ];
      };
    # Stands in for GitHub: the upstream repository over git://.
    github = {
      environment.systemPackages = [ pkgs.git ];
      networking.firewall.allowedTCPPorts = [ 9418 ];
    };
  };

  testScript = ''
    import json

    github.wait_for_unit("multi-user.target")
    github.succeed(
        "git init -q --bare -b main /srv/git/upstream.git",
        "git -C /srv/git/upstream.git config daemon.receivepack true",
        "git clone -q /srv/git/upstream.git /tmp/seed && cd /tmp/seed && echo '# Demo' > README.md"
        " && git add README.md && git -c user.name=t -c user.email=t@example.com commit -qm init"
        " && git push -q origin main",
        "chmod -R a+rwX /srv/git",
        "systemd-run -u gitd ${pkgs.git}/bin/git daemon --reuseaddr --export-all --enable=receive-pack"
        " --base-path=/srv/git /srv/git",
    )
    github.wait_for_open_port(9418)
    ip = github.succeed("ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1").strip()
    upstream = f"git://{ip}/upstream.git"

    def branch_log(head):
        return github.succeed(
            f"git --git-dir=/srv/git/upstream.git log --format='%an|%s' main..refs/heads/{head}"
        ).strip().splitlines()

    def gh_state(name):
        return clankstation.succeed(
            f"cat /var/lib/clankstation/users/default/home/.gh-stub/{name} 2>/dev/null || true"
        )

    def turn(task, cmd):
        clankstation.succeed(f"rm -f /var/lib/clankstation/tasks/{task}/status.json")
        clankstation.succeed(f"su admin -c \"{cmd}\" 2>/dev/null")
        clankstation.wait_until_succeeds(f"test -f /var/lib/clankstation/tasks/{task}/status.json", timeout=120)
        st = json.loads(clankstation.succeed(f"cat /var/lib/clankstation/tasks/{task}/status.json"))
        assert st["state"] == "done", st

    def pr(task):
        return json.loads(clankstation.succeed(f"cat /var/lib/clankstation/tasks/{task}/result/pr.json"))

    clankstation.wait_for_unit("docker.service")
    clankstation.succeed("docker load < ${testImage}")
    clankstation.succeed(
        f"clankctl project add demo {upstream}",
        # Not a github.com remote: pull requests are off until turned on.
        "clankctl project list | grep -E '^demo +[a-z-]+ +- '",
        "clankctl project set demo pull-requests on",
        "clankctl project list | grep -E '^demo +[a-z-]+ +PRs '",
        "clankctl shell sh -c 'v=$HOME/.local/share/claude/versions/0.0.0-stub"
        " && mkdir -p ~/.local/bin $(dirname $v) && cat > $v && chmod +x $v"
        " && ln -s $v ~/.local/bin/claude' < ${stubClaude}",
        "clankctl shell sh -c 'cat > ~/.local/bin/gh && chmod +x ~/.local/bin/gh' < ${stubGh}",
    )

    # Turn 1: a readable branch; Claude's uncommitted file is committed as the
    # user, pushed, and a draft pull request opened against main.
    out = clankstation.succeed("su admin -c \"clankctl run demo 'Make the form send mail'\" 2>/dev/null")
    task = out.strip().splitlines()[0]
    head = clankstation.succeed(f"sed -n 's/^head=//p' /var/lib/clankstation/tasks/{task}/task.env").strip()
    assert head == f"clank/make-the-form-send-mail-{task[-4:]}", head
    clankstation.wait_until_succeeds(f"test -f /var/lib/clankstation/tasks/{task}/status.json", timeout=120)
    assert branch_log(head) == ["alice|Make the form send mail"], branch_log(head)
    author = github.succeed(f"git --git-dir=/srv/git/upstream.git log -1 --format=%ae refs/heads/{head}").strip()
    assert author == "42+alice@users.noreply.github.com", author
    assert gh_state("created").strip() == "1 base=main draft=true title=Make the form send mail", gh_state("created")
    body = gh_state("body")
    assert "Make the form send mail" in body and "Turn 1 done." in body, body
    p = pr(task)
    assert p["number"] == 1 and p["isDraft"] and p["branch"] == head and "error" not in p, p

    # Turn 2: Claude commits by itself; the box adds nothing, pushes, and
    # updates the same pull request.
    turn(task, f"clankctl resume {task} 'Add more'")
    assert branch_log(head) == ["Claude|Add more to the form", "alice|Make the form send mail"], branch_log(head)
    assert gh_state("edited").strip() == "1", gh_state("edited")
    assert "Turn 2 done." in gh_state("body")
    assert pr(task)["number"] == 1

    # Not signed in to GitHub: the turn ends well, nothing is pushed, and
    # the task says why.
    clankstation.succeed("touch /var/lib/clankstation/users/default/home/.gh-stub/signed-out")
    turn(task, f"clankctl resume {task} 'Once more'")
    p = pr(task)
    assert p["error"] == "Sign in to GitHub in Settings to open pull requests." and p["number"] == 1, p
    assert len(branch_log(head)) == 2

    # Signed in again, and the pull request was merged meanwhile: the next
    # turn opens a new one (with the work left from the last turn).
    clankstation.succeed(
        "rm /var/lib/clankstation/users/default/home/.gh-stub/signed-out",
        f"cd /var/lib/clankstation/tasks/{task}/result && jq '.state = \"MERGED\"' pr.json > x && mv x pr.json"
        " && chown clankstation:clankstation pr.json",
    )
    turn(task, f"clankctl resume {task} 'And again'")
    assert len(branch_log(head)) == 3, branch_log(head)
    assert gh_state("created").strip().splitlines()[-1].startswith("2 base=main"), gh_state("created")
    p = pr(task)
    assert p["number"] == 2 and "error" not in p, p

    # Merged on GitHub: `clankctl pr refresh` (what the app runs) picks it up.
    clankstation.succeed(
        "cd /var/lib/clankstation/users/default/home/.gh-stub"
        " && jq '.state = \"MERGED\" | .isDraft = false' pr-2.json > x && mv x pr-2.json"
        " && chown clankstation:clankstation pr-2.json"
    )
    out = clankstation.succeed(f"su admin -c 'clankctl pr refresh {task}'")
    assert out.startswith("#2 MERGED https://github.example/alice/upstream/pull/2"), out
    p = pr(task)
    assert p["state"] == "MERGED" and not p["isDraft"] and p["branch"] == head, p

    # Pull requests off: the next task opens none.
    clankstation.succeed("clankctl project set demo pull-requests off")
    out = clankstation.succeed("su admin -c \"clankctl run demo 'Something else'\" 2>/dev/null")
    other = out.strip().splitlines()[0]
    clankstation.wait_until_succeeds(f"test -f /var/lib/clankstation/tasks/{other}/status.json", timeout=120)
    clankstation.fail(f"test -e /var/lib/clankstation/tasks/{other}/result/pr.json")
    assert gh_state("count").strip() == "2"
  '';
}
