{
  description = "NixOS for Seeed reComputer J501 Mini carrier board (NVIDIA Jetson AGX Orin)";

  nixConfig = {
    extra-substituters = [ "https://ted.cachix.org" ];
    extra-trusted-public-keys = [
      "ted.cachix.org-1:nmMqGqqYi74uo0sMW7Gt0BY2qvaaFG6lOfibBpcxhFw="
    ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    jetpack-nixos = {
      url = "github:anduril/jetpack-nixos";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko/latest";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      jetpack-nixos,
      disko,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      crossConfig = {
        nixpkgs = {
          buildPlatform.system = "x86_64-linux";
          hostPlatform.system = "aarch64-linux";
        };
      };

      # Stub settings required for Nix evaluation of the flash-script NixOS config.
      # These are not used at runtime — the flash script only needs the firmware derivations.
      flashStubs = {
        nixpkgs.config.allowUnfree = true;
        hardware.graphics.enable = true;
        fileSystems."/".fsType = "tmpfs";
        boot.loader.grub.enable = false;
        boot.loader.systemd-boot.enable = false;
        boot.zfs.forceImportRoot = false;
        system.stateVersion = "26.05";
      };

      commonModules = [
        self.nixosModules.default
        flashStubs
      ];
    in
    {
      nixosModules.default =
        { ... }:
        {
          imports = [
            jetpack-nixos.nixosModules.default
            ./modules/default.nix
          ];
        };

      nixosConfigurations.j501-agx-orin-32gb = nixpkgs.lib.nixosSystem {
        modules = commonModules ++ [
          crossConfig
          ./configurations/j501-agx-orin-32gb.nix
        ];
      };

      nixosConfigurations.board-j501-agx-orin-32gb = nixpkgs.lib.nixosSystem {
        modules = [
          self.nixosModules.default
          disko.nixosModules.disko
          crossConfig
          {
            nixpkgs.config.allowUnfree = true;
            hardware.graphics.enable = true;
            system.stateVersion = "26.05";
          }
          ./configurations/j501-agx-orin-32gb.nix
          ./configurations/board.nix
        ];
      };

      packages.x86_64-linux = {
        flash-j501-agx-orin-32gb =
          self.nixosConfigurations.j501-agx-orin-32gb.config.system.build.initrdFlashScript;
        board-j501-agx-orin-32gb-flash =
          self.nixosConfigurations.board-j501-agx-orin-32gb.config.system.build.initrdFlashScript;
        board-j501-agx-orin-32gb-toplevel =
          self.nixosConfigurations.board-j501-agx-orin-32gb.config.system.build.toplevel;
      };

      checks.x86_64-linux = {
        flash-j501-agx-orin-32gb = self.packages.x86_64-linux.flash-j501-agx-orin-32gb;
      };

      formatter = lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ] (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
