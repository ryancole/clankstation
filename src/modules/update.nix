# Updates from this repo (design: section 5.2). `clankctl update` rebuilds
# the box from the flake on GitHub, using the configuration it was installed
# as. Manual only: nothing updates on a timer.
#
# From the app (S7): clank-web runs as the unprivileged service user, so it
# asks for a check or an update by writing `check` or `update` to
# settings/update-request. A path unit starts clankstation-update.service
# (root), which runs `clankctl update [--check]` and writes the result to
# update/ (root-owned): <action>.json and <action>.log. The update runs
# outside clank-web, which the rebuild may restart.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.clankstation.update;
  data = "/var/lib/clankstation";
  request = "${data}/settings/update-request";
  out = "${data}/update";

  run = pkgs.writeShellScript "clankstation-update" ''
    set -u
    action=$(head -c 16 ${request} 2>/dev/null | tr -dc a-z || true)
    rm -f ${request}
    case "$action" in
      check) args=(--check) ;;
      update) args=() ;;
      *) echo "unknown request: $action"; exit 0 ;;
    esac
    # While this runs, /run/clankstation-update (RuntimeDirectory) says so.
    echo "$action" > /run/clankstation-update/action
    started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '{"started":"%s"}\n' "$started" > ${out}/$action.json.tmp
    mv ${out}/$action.json.tmp ${out}/$action.json
    code=0
    ${lib.getExe config.clankstation.clankctl.package} update "''${args[@]}" \
      > ${out}/$action.log 2>&1 || code=$?
    printf '{"started":"%s","finished":"%s","exit":%d}\n' \
      "$started" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$code" > ${out}/$action.json.tmp
    mv ${out}/$action.json.tmp ${out}/$action.json
  '';
in
{
  options.clankstation.update = {
    flake = lib.mkOption {
      type = lib.types.str;
      default = "github:ryancole/clankstation/master?dir=src";
      description = "Flake that `clankctl update` rebuilds the box from.";
    };
    configuration = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Name of this box's entry in the flake's nixosConfigurations (set by
        the flake for each host). null disables `clankctl update`.
      '';
    };
  };

  config = {
    environment.etc."clankstation/update.env".text = ''
      flake=${cfg.flake}
      configuration=${toString cfg.configuration}
    '';

    systemd.tmpfiles.settings."20-clankstation-update".${out}.d = {
      mode = "0755";
      user = "root";
      group = "root";
    };

    systemd.paths.clankstation-update = {
      description = "Clankstation update requests from the app";
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathExists = request;
    };

    systemd.services.clankstation-update = {
      description = "Clankstation update (requested from the app)";
      unitConfig.RequiresMountsFor = [ data ];
      # The rebuild this runs must not stop or restart it.
      restartIfChanged = false;
      stopIfChanged = false;
      # clankctl update calls nix, nixos-rebuild and nixos-version from the
      # system, as it does for an admin over SSH.
      path = [ "/run/current-system/sw" ];
      environment.HOME = "/root";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = run;
        RuntimeDirectory = "clankstation-update";
        RuntimeDirectoryMode = "0755";
      };
    };
  };
}
