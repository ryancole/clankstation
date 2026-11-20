{
  description = "Clankstation: a NixOS appliance where AI coding agents run tasks unattended";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko = {
      url = "github:nix-community/disko/v1.13.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
    }:
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
      nixosModules.default = {
        imports = [
          disko.nixosModules.disko
          ./modules
        ];
      };

      nixosConfigurations = {
        # The appliance itself (real hardware).
        clankstation = mkHost [ ./hosts/clankstation ];

        # Same system, plus VM settings for local testing.
        dev-vm = mkHost [
          ./hosts/clankstation
          ./hosts/dev-vm
        ];
      };

      checks.${system} = {
        m0-boot = import ./tests/m0-boot.nix { inherit self pkgs; };
        m2-docker = import ./tests/m2-docker.nix { inherit self pkgs; };
      }
      // import ./tests/m1-storage.nix { inherit self pkgs disko; };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
