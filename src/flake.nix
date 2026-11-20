{
  description = "Clankstation: a NixOS appliance where AI coding agents run tasks unattended";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      mkHost =
        modules:
        nixpkgs.lib.nixosSystem {
          modules = [
            { nixpkgs.hostPlatform = system; }
            self.nixosModules.default
          ]
          ++ modules;
        };
    in
    {
      # All Clankstation modules. Hosts import this and set host-specific options.
      nixosModules.default = ./modules;

      nixosConfigurations = {
        # The appliance itself (real hardware).
        clankstation = mkHost [ ./hosts/clankstation ];

        # Same system, plus build-vm settings for local testing.
        dev-vm = mkHost [
          ./hosts/clankstation
          ./hosts/dev-vm
        ];
      };

      checks.${system} = {
        m0-boot = import ./tests/m0-boot.nix { inherit self pkgs; };
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
