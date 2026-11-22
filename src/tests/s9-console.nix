# S9: the box's own screen. tty1 shows the status page instead of a login
# prompt: before Tailscale, how to set the box up (by name and LAN address);
# then the tasks as they change. Keys typed there go nowhere, and Alt+F2
# still gives the admin login. Screenshots go to the test's output.
#
# Joined to a tailnet (the app's address and its QR code) is covered by the
# Go tests and checked on the dev VM: VM tests have no Let's Encrypt.
{ self, pkgs }:
pkgs.testers.runNixOSTest {
  name = "s9-console";

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
    def task(id, files):
        d = f"/var/lib/clankstation/tasks/{id}"
        clankstation.succeed(f"mkdir -p {d}/result")
        files["task.env"] = "project=bakery\nbranch=main\ncreated=2026-11-22T12:00:00Z\nuser=default\nenv=linux-default\n"
        for name, text in files.items():
            clankstation.succeed(f"cat > {d}/{name} <<'EOF'\n{text}\nEOF")
        clankstation.succeed(f"chown -R clankstation:clankstation {d}")

    clankstation.wait_for_unit("clankstation-console.service")
    assert clankstation.succeed("systemctl show -p User --value clankstation-console").strip() == "clankstation"
    # No login prompt on tty1.
    clankstation.fail("systemctl is-active getty@tty1.service")

    # Not on Tailscale yet: how to set the box up.
    clankstation.wait_until_tty_matches("1", "Set up this box")
    clankstation.wait_until_tty_matches("1", "http://clankstation.local")
    clankstation.wait_until_tty_matches("1", r"or http://10\.0\.2\.15")  # QEMU's network: the only one in a one-machine test
    clankstation.wait_until_tty_matches("1", "Nothing running")
    clankstation.wait_until_tty_matches("1", "For an admin login, press Alt\\+F2")
    clankstation.wait_until_tty_matches("1", r"Version 26\.05")
    # What the box is using: memory and both disks (no GPU in a VM test).
    clankstation.wait_until_tty_matches("1", "This box")
    for name in ["Memory", "Projects", "System"]:
        clankstation.wait_until_tty_matches("1", name + r" .* of \d")
    clankstation.screenshot("setup")

    # Tasks: one needs an answer, one waits in line, one is preparing.
    task("t-20261122-120000-aaaa", {
        "prompts.log": "--- 2026-11-22T12:00:00Z run\nMake the contact form send an email",
        "status.json": '{"state":"done","mode":"headless","exit_code":0,"finished":"2026-11-22T12:20:00Z"}',
        "result/summary.md": "Done.\n\nShould it go to info@ or to you?",
    })
    task("t-20261122-130000-bbbb", {
        "prompts.log": "--- 2026-11-22T13:00:00Z run\nUpdate the menu page",
        "queued": "2026-11-22T13:00:00Z",
    })
    clankstation.succeed("systemd-run -u fake-prepare --uid clankstation sleep 1000")
    pid = clankstation.succeed("systemctl show -p MainPID --value fake-prepare").strip()
    task("t-20261122-140000-cccc", {
        "prompts.log": "--- 2026-11-22T14:00:00Z run\nFix the opening hours",
        "prepare.pid": pid,
    })
    clankstation.wait_until_tty_matches("1", "1 working   1 waiting   1 needs you")
    clankstation.wait_until_tty_matches("1", "Needs you Make the contact form send an email")
    clankstation.wait_until_tty_matches("1", "Working   Fix the opening hours")
    clankstation.screenshot("tasks")

    # A failed update shows as a problem.
    clankstation.succeed(
        "mkdir -p /var/lib/clankstation/update",
        "echo '{\"started\":\"a\",\"finished\":\"b\",\"exit\":1}' > /var/lib/clankstation/update/update.json",
        "echo 'clankctl: could not reach GitHub' > /var/lib/clankstation/update/update.log",
    )
    clankstation.wait_until_tty_matches("1", "! The update didn't work. could not reach GitHub")

    # The tasks finish: the page follows.
    clankstation.succeed("systemctl stop fake-prepare", "rm -rf /var/lib/clankstation/tasks/*")
    clankstation.wait_until_tty_matches("1", "Nothing running")

    # Typing at the page does nothing; Alt+F2 is the admin login.
    clankstation.send_chars("hello world\n")
    clankstation.sleep(4)
    assert "hello" not in clankstation.get_tty_text("1")
    assert clankstation.succeed("systemctl is-active clankstation-console").strip() == "active"
    # (The tty checks read a console whether it is on screen or not, so also
    # check which one is.)
    clankstation.succeed("grep -qx tty1 /sys/class/tty/tty0/active")
    clankstation.send_key("alt-f2")
    clankstation.wait_until_succeeds("grep -qx tty2 /sys/class/tty/tty0/active")
    clankstation.wait_until_tty_matches("2", "login:")
    clankstation.send_key("alt-f1")
    clankstation.wait_until_succeeds("grep -qx tty1 /sys/class/tty/tty0/active")
    clankstation.wait_until_tty_matches("1", "Set up this box")
    clankstation.sleep(1)
    clankstation.screenshot("back")

    # It comes back if it stops.
    clankstation.succeed("systemctl kill clankstation-console")
    clankstation.wait_until_succeeds("systemctl is-active clankstation-console")
    clankstation.wait_until_tty_matches("1", "Set up this box")
  '';
}
