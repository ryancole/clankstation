# Updates from this repo (design: section 5.2). `clankctl update` rebuilds
# the box from the flake on GitHub, using the configuration it was installed
# as. Manual only: nothing updates on a timer.
{ config, lib, ... }:
let
  cfg = config.clankstation.update;
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

  config.environment.etc."clankstation/update.env".text = ''
    flake=${cfg.flake}
    configuration=${toString cfg.configuration}
  '';
}
