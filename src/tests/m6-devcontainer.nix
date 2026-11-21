# M6: a repo with a devcontainer.json gets its own environment.
#
#   - the image is built with the devcontainers CLI from the repo's config,
#     plus the agent layer (remoteUser remapped to the clankstation uid)
#   - containerEnv is set; postCreateCommand runs once per task and
#     postStartCommand on every turn
#   - the image is reused while the devcontainer files are unchanged
#   - `--template linux-default` opts a project out
#   - docker compose configs are refused with a clear message
#
# Offline: the devcontainer is a Dockerfile on a digest-pinned ubuntu:26.04,
# and a stub `claude` (installer-style symlink) records what it saw.
{ self, pkgs }:
let
  ubuntu = pkgs.dockerTools.pullImage (import ../images/linux-default/base-image.nix);

  stubClaude = pkgs.writeText "claude-stub" ''
    #!/bin/sh
    prompt= sid=
    while [ $# -gt 0 ]; do
      case "$1" in
        -p) prompt="$2"; shift 2 ;;
        --resume) sid="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    echo '{"type":"system","subtype":"init","session_id":"stub-session-1"}'
    {
      echo "prompt=$prompt"
      echo "user=$(id -un 2>/dev/null) uid=$(id -u)"
      echo "env=$DEMO_ENV"
      echo "marker=$(cat /etc/demo-marker 2>/dev/null)"
      echo "created=$(cat .post-create 2>/dev/null)"
    } >> evidence.txt
    echo '{"type":"result","is_error":false,"result":"stub ok","session_id":"stub-session-1"}'
  '';

  devcontainerJson = pkgs.writeText "devcontainer.json" ''
    // JSONC: comments and trailing commas are allowed.
    {
      "name": "demo",
      "build": { "dockerfile": "Dockerfile" },
      "remoteUser": "ubuntu",
      "containerEnv": { "DEMO_ENV": "from-devcontainer" },
      "postCreateCommand": "echo created-by-postCreate > /workspace/.post-create",
      "postStartCommand": ["sh", "-c", "echo started >> /workspace/.post-start"],
    }
  '';
  dockerfile = pkgs.writeText "Dockerfile" ''
    FROM ubuntu:26.04
    RUN echo devcontainer-image > /etc/demo-marker
  '';
  composeJson = pkgs.writeText "devcontainer.json" ''
    { "name": "compose", "dockerComposeFile": "compose.yml", "service": "app", "workspaceFolder": "/w" }
  '';
  composeYml = pkgs.writeText "compose.yml" ''
    services:
      app:
        image: ubuntu:26.04
  '';
in
pkgs.testers.runNixOSTest {
  name = "m6-devcontainer";

  nodes.clankstation =
    { lib, ... }:
    {
      imports = [
        self.nixosModules.default
        ../hosts/clankstation
      ];
      disko.enableConfig = false;
      virtualisation = {
        memorySize = 3072;
        diskSize = 8192;
      };
      systemd.timers.clankstation-image-linux-default.enable = lib.mkForce false;
    };

  testScript = ''
    import re

    tasks = "/var/lib/clankstation/tasks"

    def make_repo(path, files):
        clankstation.succeed(f"mkdir -p {path} && cd {path} && git init -q -b main && echo '# Demo' > README.md")
        for dest, src in files.items():
            clankstation.succeed(f"mkdir -p $(dirname {path}/{dest}) && cp {src} {path}/{dest}")
        clankstation.succeed(
            f"cd {path} && git add -A && git -c user.name=t -c user.email=t@example.com commit -qm init",
            f"chown -R clankstation:clankstation {path}",
        )

    def run(project, prompt):
        out = clankstation.succeed(f"clankctl run {project} '{prompt}' 2>/dev/null")
        return out.strip().splitlines()[0]

    def wait_finished(task):
        clankstation.wait_until_succeeds(f"test -f {tasks}/{task}/status.json", timeout=300)

    def show(task):
        return clankstation.succeed(f"clankctl show {task}")

    clankstation.wait_for_unit("docker.service")
    clankstation.succeed(
        "docker load < ${ubuntu}",
        # Stand-in default image for the linux-default case.
        "docker tag ubuntu:26.04 clankstation/linux-default:latest",
        "clankctl shell sh -c 'v=$HOME/.local/share/claude/versions/0.0.0-stub"
        " && mkdir -p ~/.local/bin $(dirname $v) && cat > $v && chmod +x $v"
        " && ln -s $v ~/.local/bin/claude' < ${stubClaude}",
    )

    make_repo("/srv/dc", {
        ".devcontainer/devcontainer.json": "${devcontainerJson}",
        ".devcontainer/Dockerfile": "${dockerfile}",
    })
    clankstation.succeed("clankctl project add dc /srv/dc")

    # --- first task: build the devcontainer, run in it ------------------------
    t1 = run("dc", "first")
    wait_finished(t1)
    s = show(t1)
    assert "State:   done" in s, s + clankstation.succeed(f"cat {tasks}/{t1}/prepare.log")
    assert re.search(r"Env:\s+devcontainer \(clankstation/dc-dc:[0-9a-f]{12}\)", s), s

    evidence = clankstation.succeed(f"cat {tasks}/{t1}/worktree/evidence.txt")
    assert "user=ubuntu uid=2000" in evidence, evidence          # remoteUser, remapped
    assert "env=from-devcontainer" in evidence, evidence         # containerEnv
    assert "marker=devcontainer-image" in evidence, evidence     # the project's Dockerfile
    assert "created=created-by-postCreate" in evidence, evidence # postCreate ran before the harness
    clankstation.succeed(f"test $(wc -l < {tasks}/{t1}/worktree/.post-start) -eq 1")
    clankstation.succeed(f"grep -q 'devcontainer build' {tasks}/{t1}/prepare.log")

    # --- resume: postStart runs again, postCreate doesn't -----------------------
    clankstation.succeed(f"clankctl resume {t1} 'second'")
    wait_finished(t1)
    assert "State:   done" in show(t1)
    clankstation.succeed(f"test $(wc -l < {tasks}/{t1}/worktree/.post-start) -eq 2")
    clankstation.succeed(f"test $(grep -c '^--- postCreateCommand:' {tasks}/{t1}/lifecycle.log) -eq 1")

    # --- a second task reuses the image ---------------------------------------
    t2 = run("dc", "again")
    wait_finished(t2)
    assert "State:   done" in show(t2)
    clankstation.fail(f"grep -q 'devcontainer build' {tasks}/{t2}/prepare.log")
    clankstation.succeed(f"test \"$(cat {tasks}/{t1}/image)\" = \"$(cat {tasks}/{t2}/image)\"")

    # --- opting out: same repo, default image ----------------------------------
    clankstation.succeed("clankctl project add --template linux-default plain /srv/dc")
    t3 = run("plain", "plain")
    wait_finished(t3)
    s = show(t3)
    assert "Env:     linux-default (clankstation/linux-default:latest)" in s, s
    evidence = clankstation.succeed(f"cat {tasks}/{t3}/worktree/evidence.txt")
    assert "env=\n" in evidence + "\n" and "marker=\n" in evidence, evidence
    clankstation.fail(f"test -e {tasks}/{t3}/worktree/.post-start")

    # --- compose devcontainers are refused clearly ------------------------------
    make_repo("/srv/compose", {
        ".devcontainer/devcontainer.json": "${composeJson}",
        ".devcontainer/compose.yml": "${composeYml}",
    })
    clankstation.succeed("clankctl project add compose /srv/compose")
    t4 = run("compose", "nope")
    wait_finished(t4)
    s = show(t4)
    assert "State:   failed" in s and "compose" in s, s

    clankstation.succeed("test -z \"$(docker ps -aq)\"")
  '';
}
