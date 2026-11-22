# S5: Tailscale login. A real tailscaled on the box and on a "phone", with
# Headscale as the coordination server (VM tests have no internet, so no
# Tailscale account and no Let's Encrypt). Checks:
#   - the first-run page on the LAN, before and after the box joins
#   - the app answers on 443 only over the tailnet, as the phone's Tailscale
#     identity, and turns away anyone Tailscale can't name
#   - a LAN device can't reach 443 at all
# Headscale can't issue ts.net certificates, so clank-web serves a test
# certificate here (-tls-cert); the real certificate is checked on the box.
{ self, pkgs }:
let
  tlsCerts = pkgs.runCommand "s5-certs" { buildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
      -out $out/headscale.pem -keyout $out/headscale-key.pem \
      -subj '/CN=headscale' -addext "subjectAltName=DNS:headscale"
    openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
      -out $out/box.pem -keyout $out/box-key.pem \
      -subj '/CN=clankstation' -addext "subjectAltName=DNS:clankstation.tailnet"
  '';
  trustHeadscale = {
    security.pki.certificateFiles = [ "${tlsCerts}/headscale.pem" ];
  };
in
pkgs.testers.runNixOSTest {
  name = "s5-tailnet";

  nodes = {
    headscale = {
      services.headscale = {
        enable = true;
        port = 8080;
        settings = {
          server_url = "https://headscale";
          ip_prefixes = [ "100.64.0.0/10" ];
          derp = {
            server = {
              enabled = true;
              region_id = 999;
              stun_listen_addr = "0.0.0.0:3478";
            };
            urls = [ ];
          };
          dns = {
            base_domain = "tailnet";
            override_local_dns = false;
          };
        };
      };
      services.nginx = {
        enable = true;
        virtualHosts.headscale = {
          addSSL = true;
          sslCertificate = "${tlsCerts}/headscale.pem";
          sslCertificateKey = "${tlsCerts}/headscale-key.pem";
          locations."/" = {
            proxyPass = "http://127.0.0.1:8080";
            proxyWebsockets = true;
          };
        };
      };
      networking.firewall = {
        allowedTCPPorts = [
          80
          443
        ];
        allowedUDPPorts = [ 3478 ];
      };
      environment.systemPackages = [ pkgs.headscale ];
    };

    clankstation =
      { lib, ... }:
      {
        imports = [
          self.nixosModules.default
          ../hosts/clankstation
          trustHeadscale
        ];
        disko.enableConfig = false;
        virtualisation.memorySize = 2048;
        systemd.timers.clankstation-image-linux-default.enable = lib.mkForce false;
        clankstation.web.extraArgs = [
          "-tls-cert"
          "${tlsCerts}/box.pem"
          "-tls-key"
          "${tlsCerts}/box-key.pem"
        ];
        environment.systemPackages = [ pkgs.curl ];
      };

    phone = {
      imports = [ trustHeadscale ];
      services.tailscale.enable = true;
      environment.systemPackages = [ pkgs.curl ];
    };

    lan = {
      environment.systemPackages = [ pkgs.curl ];
    };
  };

  testScript = ''
    import json

    start_all()
    headscale.wait_for_unit("headscale")
    headscale.wait_for_open_port(443)
    clankstation.wait_for_unit("tailscaled.service")
    clankstation.wait_for_unit("clankstation-web.service")
    clankstation.wait_for_open_port(80)
    clankstation.wait_for_open_port(443)

    # The service user is Tailscale's operator (it may start the sign-in).
    clankstation.wait_until_succeeds("tailscale debug prefs | grep -q '\"OperatorUser\": \"clankstation\"'")

    # --- Before joining: the LAN gets the first-run page, and nothing on 443 ---
    page = lan.succeed("curl -sf http://clankstation/")
    assert "Connect to Tailscale" in page, page
    lan.fail("curl -sk --max-time 5 https://clankstation/")

    # --- Join the tailnet (Headscale stands in for Tailscale's sign-in) --------
    headscale.succeed("headscale users create alice")
    key = headscale.succeed("headscale preauthkeys -u 1 create --reusable").strip()
    up = f"tailscale up --login-server https://headscale --auth-key {key}"
    clankstation.succeed(up)
    phone.succeed(up)
    phone.wait_until_succeeds("tailscale ping clankstation")
    box_ip = clankstation.succeed("tailscale ip -4").strip()

    # Joined: the LAN page moves on (here to the HTTPS step: Headscale gives no
    # certificates), and can no longer start a sign-in.
    lan.wait_until_succeeds("curl -sf http://clankstation/ | grep -q 'Enable HTTPS'")
    lan.succeed("curl -s -o /dev/null -X POST -H 'Origin: http://clankstation' http://clankstation/setup/connect")
    clankstation.succeed("tailscale status --json | grep -q '\"BackendState\": \"Running\"'")

    # --- The phone gets in, as its Tailscale user ------------------------------
    me = json.loads(phone.succeed(f"curl -sf --cacert ${tlsCerts}/box.pem --resolve clankstation.tailnet:443:{box_ip} https://clankstation.tailnet/api/me"))
    assert me["login"].startswith("alice"), me
    assert me["node"], me
    assert "<!doctype html>" in phone.succeed(f"curl -sf -k https://{box_ip}/").lower()
    assert phone.succeed(f"curl -sf -k https://{box_ip}/api/tasks").strip() == "[]"

    # --- Nobody Tailscale can't name: here, the box itself over loopback ------
    out = clankstation.succeed("curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1/api/tasks")
    assert out == "403", out
    assert "Tailscale network" in clankstation.succeed("curl -sk https://127.0.0.1/")

    # --- And the LAN still can't reach 443 --------------------------------------
    lan.fail("curl -sk --max-time 5 https://clankstation/")
  '';
}
