# The installer: `clankstation-install` plus the prebuilt systems it installs.
# Used by the installer ISO (iso.nix) and by the installer VM test.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.clankstation.installer;

  target = lib.types.submodule {
    options = {
      system = lib.mkOption {
        type = lib.types.package;
        description = "The system to install (a nixosConfiguration's toplevel).";
      };
      disko = lib.mkOption {
        type = lib.types.package;
        description = "That configuration's disko destroy-format-mount script.";
      };
    };
  };

  installer = pkgs.writeShellApplication {
    name = "clankstation-install";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      gnugrep
      gnused
      nixos-install-tools
      util-linux
    ];
    text = ''
      SYSTEM_TWO=${cfg.twoDisk.system}
      DISKO_TWO=${lib.getExe cfg.twoDisk.disko}
      SYSTEM_ONE=${cfg.oneDisk.system}
      DISKO_ONE=${lib.getExe cfg.oneDisk.disko}
    ''
    + builtins.readFile ./clankstation-install.sh;
  };
in
{
  options.clankstation.installer = {
    twoDisk = lib.mkOption {
      type = target;
      description = "What to install with a separate data disk.";
    };
    oneDisk = lib.mkOption {
      type = target;
      description = "What to install with everything on one disk.";
    };
  };

  config = {
    environment.systemPackages = [ installer ];
    # The install copies these closures from the installer's own store.
    system.extraDependencies = [
      cfg.twoDisk.system
      cfg.oneDisk.system
    ];
  };
}
