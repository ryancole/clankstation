# S7: the box's settings in the app. Settings shows the version and free
# space, checks for updates and updates the box, through the root
# clankstation-update service that the unprivileged app asks with a file.
#
# VM tests have no network, so stub `nix` and `nixos-rebuild` stand in for
# GitHub and the rebuild (as in m10-cleanup-update). The stub rebuild
# restarts the app, as a real update that changes it does. A real update is
# checked on an installed box.
{ self, pkgs }:
let
  stubs = pkgs.runCommand "update-stubs" { } ''
    mkdir -p $out/bin
    cat > $out/bin/nix <<'EOF'
    #!/bin/sh
    echo "$*" >> /var/log/stub-calls
    if [ -e /var/log/stub-offline ]; then echo "error: unable to download" >&2; exit 1; fi
    echo '{"revision":"rev-2"}'
    EOF
    cat > $out/bin/nixos-rebuild <<'EOF'
    #!/bin/sh
    echo "nixos-rebuild $*" >> /var/log/stub-calls
    echo "building the system configuration..."
    sleep 5
    systemctl restart clankstation-web.service
    sleep 5
    echo "activating the configuration..."
    EOF
    chmod +x $out/bin/*
  '';
in
pkgs.testers.runNixOSTest {
  name = "s7-box";

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
      clankstation.update.configuration = "clankstation";
      system.configurationRevision = "rev-1";
      systemd.services.clankstation-update.path = lib.mkBefore [ stubs ];
      environment.systemPackages = [ pkgs.curl ];
    };

  testScript = ''
    import json

    base = "http://127.0.0.1:8080"

    def box():
        return json.loads(clankstation.succeed(f"curl -sf {base}/api/box"))

    def post(path, origin=base):
        return clankstation.succeed(
            f"curl -s -o /dev/null -w '%{{http_code}}' -X POST -H 'Content-Type: application/json'"
            f" -H 'Origin: {origin}' -d '{{}}' {base}{path}"
        ).strip()

    def wait_idle():
        clankstation.wait_until_succeeds(
            f"curl -sf {base}/api/box | grep -v '\"busy\"'", timeout=120
        )
        return box()

    clankstation.wait_for_unit("clankstation-web.service")
    clankstation.wait_for_unit("clankstation-update.path")
    clankstation.wait_for_open_port(8080)

    with subtest("version and free space"):
        b = box()
        assert b["version"]["revision"] == "rev-1", b
        assert b["version"]["nixos"].startswith("26."), b
        assert b["updates"] is True and "busy" not in b, b
        assert not b["restart_needed"], b
        names = [d["name"] for d in b["disks"]]
        assert names == ["Tasks and projects", "System"], b
        assert all(0 < d["free"] <= d["size"] for d in b["disks"]), b

    with subtest("other sites can't update the box"):
        assert post("/api/box/update", origin="https://evil.example") == "403"
        clankstation.fail("test -e /var/lib/clankstation/settings/update-request")

    with subtest("check for updates"):
        assert post("/api/box/check") == "202"
        b = wait_idle()
        assert b["check"]["ok"] and b["check"]["latest"] == "rev-2", b
        assert not b["check"]["up_to_date"], b
        clankstation.fail("grep nixos-rebuild /var/log/stub-calls")
        # The root service wrote the result; the request is gone.
        clankstation.succeed("stat -c %U /var/lib/clankstation/update/check.json | grep -x root")
        clankstation.fail("test -e /var/lib/clankstation/settings/update-request")

    with subtest("update now, through an app restart"):
        pid = clankstation.succeed("systemctl show -p MainPID --value clankstation-web").strip()
        assert post("/api/box/update") == "202"
        clankstation.wait_until_succeeds(f"curl -sf {base}/api/box | grep '\"busy\":\"update\"'")
        # A second request while it runs is refused.
        assert post("/api/box/check") == "400"
        b = wait_idle()
        u = b["update"]
        assert u["ok"] and u["message"] == "Updated.", u
        assert "Now at:" in u["log"] and "activating" in u["log"], u
        calls = clankstation.succeed("cat /var/log/stub-calls")
        assert "nixos-rebuild switch --refresh --flake github:ryancole/clankstation/master?dir=src#clankstation" in calls, calls
        # The app restarted during the update, and the update kept going.
        assert clankstation.succeed("systemctl show -p MainPID --value clankstation-web").strip() != pid

    with subtest("a check that can't reach GitHub says so"):
        clankstation.succeed("touch /var/log/stub-offline")
        assert post("/api/box/check") == "202"
        b = wait_idle()
        assert not b["check"]["ok"], b
        assert "could not reach" in b["check"]["message"], b
        # The last update's result is still there.
        assert b["update"]["ok"], b

    with subtest("an update the box restarted during shows as interrupted"):
        clankstation.succeed(
            "echo '{\"started\":\"2026-11-22T00:00:00Z\"}' > /var/lib/clankstation/update/update.json"
        )
        b = box()
        assert b["update"]["interrupted"] and not b["update"]["ok"], b
  '';
}
