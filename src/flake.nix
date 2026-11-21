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

      # What the installer installs, from two configurations (two-disk, one-disk).
      installTargets = configs: {
        twoDisk = {
          system = configs.clankstation.config.system.build.toplevel;
          disko = configs.clankstation.config.system.build.destroyFormatMount;
        };
        oneDisk = {
          system = configs.clankstation-one-disk.config.system.build.toplevel;
          disko = configs.clankstation-one-disk.config.system.build.destroyFormatMount;
        };
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
        # The appliance itself (real hardware): OS disk + separate data disk.
        clankstation = mkHost [ ./hosts/clankstation ];

        # The same, with data on the OS disk.
        clankstation-one-disk = mkHost [
          ./hosts/clankstation
          { clankstation.storage.dataDisk = null; }
        ];

        # Same system, plus VM settings for local testing.
        dev-vm = mkHost [
          ./hosts/clankstation
          ./hosts/dev-vm
        ];

        # The installer ISO, carrying both appliance variants.
        installer = nixpkgs.lib.nixosSystem {
          modules = [
            { nixpkgs.hostPlatform = system; }
            ./installer
            ./installer/iso.nix
            { clankstation.installer = installTargets self.nixosConfigurations; }
          ];
        };
      };

      packages.${system} = {
        # nix build ./src#installer-iso  ->  result/iso/clankstation-installer-*.iso
        installer-iso = self.nixosConfigurations.installer.config.system.build.isoImage;
      };

      checks.${system} = {
        m0-boot = import ./tests/m0-boot.nix { inherit self pkgs; };
        m2-docker = import ./tests/m2-docker.nix { inherit self pkgs; };
        m3-harness = import ./tests/m3-harness.nix { inherit self pkgs; };
        m4-task = import ./tests/m4-task.nix { inherit self pkgs; };
        m5-takeover = import ./tests/m5-takeover.nix { inherit self pkgs; };
        m6-devcontainer = import ./tests/m6-devcontainer.nix { inherit self pkgs; };
        m7-installer = import ./tests/m7-installer.nix { inherit self pkgs; };
      }
      // import ./tests/m1-storage.nix { inherit self pkgs disko; };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
