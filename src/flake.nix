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

      # `update` is the host's name in nixosConfigurations, which
      # `clankctl update` rebuilds from GitHub (null: updates off).
      mkHost =
        update: modules:
        nixpkgs.lib.nixosSystem {
          modules = [
            {
              nixpkgs.hostPlatform = system;
              clankstation.update.configuration = update;
              # Shown by `nixos-version --configuration-revision`.
              system.configurationRevision = self.rev or self.dirtyRev or null;
            }
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
        clankstation = mkHost "clankstation" [ ./hosts/clankstation ];

        # The same, with data on the OS disk.
        clankstation-one-disk = mkHost "clankstation-one-disk" [
          ./hosts/clankstation
          { clankstation.storage.dataDisk = null; }
        ];

        # Same system, plus VM settings for local testing. Rebuilt from WSL,
        # not updated from GitHub.
        dev-vm = mkHost null [
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
        # nix build ./src#clank-web  (the web service, its app embedded)
        clank-web = pkgs.callPackage ./pkgs/clank-web { };
      };

      checks.${system} = {
        m0-boot = import ./tests/m0-boot.nix { inherit self pkgs; };
        m2-docker = import ./tests/m2-docker.nix { inherit self pkgs; };
        m3-harness = import ./tests/m3-harness.nix { inherit self pkgs; };
        m4-task = import ./tests/m4-task.nix { inherit self pkgs; };
        m5-takeover = import ./tests/m5-takeover.nix { inherit self pkgs; };
        m6-devcontainer = import ./tests/m6-devcontainer.nix { inherit self pkgs; };
        m7-installer = import ./tests/m7-installer.nix { inherit self pkgs; };
        m8-windows-plumbing = import ./tests/m8-windows-plumbing.nix { inherit self pkgs; };
        m10-cleanup-update = import ./tests/m10-cleanup-update.nix { inherit self pkgs; };
        s1-web = import ./tests/s1-web.nix { inherit self pkgs; };
        s2-actions = import ./tests/s2-actions.nix { inherit self pkgs; };
        s3-terminal = import ./tests/s3-terminal.nix { inherit self pkgs; };
        s4-queue = import ./tests/s4-queue.nix { inherit self pkgs; };
        s5-tailnet = import ./tests/s5-tailnet.nix { inherit self pkgs; };
        s6-push = import ./tests/s6-push.nix { inherit self pkgs; };
        s7-box = import ./tests/s7-box.nix { inherit self pkgs; };
        s9-console = import ./tests/s9-console.nix { inherit self pkgs; };
        s10-pull-requests = import ./tests/s10-pull-requests.nix { inherit self pkgs; };
      }
      // import ./tests/m1-storage.nix { inherit self pkgs disko; };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
