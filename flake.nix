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

      nativeConfig = {
        nixpkgs = {
          buildPlatform.system = "aarch64-linux";
          hostPlatform.system = "aarch64-linux";
        };
      };

      pkgsHost = nixpkgs.legacyPackages.x86_64-linux;

      # Deploy wrapper that refuses to run against a booted Tegra system.
      # nixos-anywhere kexecs into a generic aarch64 image unless the target
      # reports VARIANT_ID=installer; that image cannot boot Tegra, so the board
      # cold-reboots into the existing OS and reconnect fails. Installs must run
      # from the J501 installer ISO (which is detected as an installer).
      deployJ501 = pkgsHost.writeShellApplication {
        name = "deploy-j501";
        runtimeInputs = [
          pkgsHost.nixos-anywhere
          pkgsHost.openssh
        ];
        text = ''
          if [ "$#" -lt 1 ]; then
            echo "usage: deploy-j501 <ip-or-host> [extra nixos-anywhere args...]" >&2
            echo "deploys j501-agx-orin (override target config via DEPLOY_FLAKE)" >&2
            exit 2
          fi

          target=$1
          shift

          sshHost="root@$target"
          echo "Probing $sshHost ..." >&2

          if ! facts=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$sshHost" '
            variant=$(. /etc/os-release 2>/dev/null; echo "''${VARIANT_ID:-}")
            compat=$(tr -d "\0" < /proc/device-tree/compatible 2>/dev/null || true)
            printf "VARIANT=%s\n" "$variant"
            printf "COMPAT=%s\n" "$compat"
          '); then
            echo "error: could not SSH to $sshHost to probe the target" >&2
            exit 1
          fi

          variant=$(printf '%s\n' "$facts" | sed -n 's/^VARIANT=//p')
          compat=$(printf '%s\n' "$facts" | sed -n 's/^COMPAT=//p')

          if [ "$variant" != "installer" ]; then
            if printf '%s' "$compat" | grep -q "nvidia,tegra"; then
              echo "refusing to deploy: $sshHost is a running system on Tegra, not the installer." >&2
              echo "nixos-anywhere would kexec into the generic aarch64 image, which cannot boot" >&2
              echo "Tegra; the board would reboot into the current system and reconnect would fail" >&2
              echo "with 'Permission denied'." >&2
              echo " - Reinstall: boot the J501 installer ISO (nix build .#iso-installer-j501), then re-run." >&2
              echo " - Update in place: nixos-rebuild switch --flake <flake>#j501-agx-orin --target-host $sshHost --sudo" >&2
            else
              echo "refusing to deploy: $sshHost is not a NixOS installer (VARIANT_ID='$variant')." >&2
            fi
            exit 1
          fi

          flakeRef="''${DEPLOY_FLAKE:-${self}#j501-agx-orin}"
          echo "Target is a NixOS installer; deploying $flakeRef ..." >&2
          exec nixos-anywhere --flake "$flakeRef" --target-host "$sshHost" "$@"
        '';
      };
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

      nixosConfigurations.flash-j501-agx-orin = nixpkgs.lib.nixosSystem {
        modules = [
          self.nixosModules.default
          crossConfig
          ./configurations/j501-agx-orin.nix
          {
            fileSystems."/".fsType = "tmpfs";
            boot.loader.grub.enable = false;
            boot.loader.systemd-boot.enable = false;
            boot.zfs.forceImportRoot = false;
            system.stateVersion = "26.05";
          }
        ];
      };

      nixosConfigurations.installer-j501 = nixpkgs.lib.nixosSystem {
        modules = [
          crossConfig
          self.nixosModules.default
          ./configurations/j501-agx-orin.nix
          {
            imports = [
              "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
            ];
            hardware.enableAllHardware = lib.mkForce false;
            boot.zfs.forceImportRoot = false;
          }
        ];
      };

      nixosConfigurations.j501-agx-orin = nixpkgs.lib.nixosSystem {
        modules = [
          self.nixosModules.default
          disko.nixosModules.disko
          crossConfig
          ./configurations/j501-agx-orin.nix
          ./configurations/board-config.nix
        ];
      };

      nixosConfigurations.native-j501-agx-orin = nixpkgs.lib.nixosSystem {
        modules = [
          self.nixosModules.default
          nativeConfig
          {
            hardware.nvidia-jetpack = {
              enable = true;
              som = "orin-agx";
              carrierBoard = "recomputer-j501-mini";
              majorVersion = "7";
              configureCuda = true;
            };
            # Stubs so the config evaluates without a real disk/bootloader.
            fileSystems."/".fsType = "tmpfs";
            boot.loader.grub.enable = false;
            boot.loader.systemd-boot.enable = false;
            boot.zfs.forceImportRoot = false;
            system.stateVersion = "26.05";
          }
        ];
      };

      nixosConfigurations.j501-agx-orin-gmsl = self.nixosConfigurations.j501-agx-orin.extendModules {
        modules = [
          {
            hardware.j501.gmsl.enable = true;
            hardware.j501.gmsl.fsyncHz = 60;
          }
        ];
      };

      nixosConfigurations.native-j501-agx-orin-gmsl =
        self.nixosConfigurations.native-j501-agx-orin.extendModules
          {
            modules = [
              {
                hardware.j501.gmsl.enable = true;
                hardware.j501.gmsl.fsyncHz = 60;
              }
            ];
          };

      packages.x86_64-linux = {
        iso-installer-j501 = self.nixosConfigurations.installer-j501.config.system.build.isoImage;
        flash-j501-agx-orin =
          self.nixosConfigurations.flash-j501-agx-orin.config.system.build.initrdFlashScript;
        j501-agx-orin = self.nixosConfigurations.j501-agx-orin.config.system.build.toplevel;
        j501-agx-orin-gmsl = self.nixosConfigurations.j501-agx-orin-gmsl.config.system.build.toplevel;
        gmsl-isx031-dtbo =
          self.nixosConfigurations.j501-agx-orin-gmsl.pkgs.callPackage ./bsp/gmsl/dtbo.nix
            { };
        gmsl-isx031-dtbo-fsync60 =
          self.nixosConfigurations.j501-agx-orin-gmsl.pkgs.callPackage ./bsp/gmsl/dtbo.nix
            { fsyncHz = 60; };
      };

      nixosConfigurations.native-j501-agx-orin-rt =
        self.nixosConfigurations.native-j501-agx-orin.extendModules
          {
            modules = [ { hardware.j501.fullPreempt.enable = true; } ];
          };

      packages.aarch64-linux =
        let
          native = self.nixosConfigurations.native-j501-agx-orin;
          native-rt = self.nixosConfigurations.native-j501-agx-orin-rt;
          npkgs = native.pkgs;
          jp = npkgs.nvidia-jetpack;
          cuda = jp.cudaPackages;
        in
        {
          cache-warm-native = npkgs.linkFarmFromDrvs "cache-warm-native" [
            native.config.boot.kernelPackages.kernel
            native-rt.config.boot.kernelPackages.kernel
            cuda.cudatoolkit
            cuda.cudnn
            cuda.tensorrt
            jp.l4t-cuda
            jp.l4t-core
            jp.l4t-multimedia
            jp.l4t-3d-core
            jp.l4t-camera
          ];
          j501-agx-orin-gmsl =
            self.nixosConfigurations.native-j501-agx-orin-gmsl.config.system.build.toplevel;
        };

      apps.x86_64-linux.deploy-j501 = {
        type = "app";
        program = "${deployJ501}/bin/deploy-j501";
      };

      checks.x86_64-linux = {
        flash-j501-agx-orin = self.packages.x86_64-linux.flash-j501-agx-orin;
        iso-installer-j501 = self.packages.x86_64-linux.iso-installer-j501;
        j501-agx-orin = self.packages.x86_64-linux.j501-agx-orin;
        j501-agx-orin-gmsl = self.packages.x86_64-linux.j501-agx-orin-gmsl;
        gmsl-isx031-dtbo = self.packages.x86_64-linux.gmsl-isx031-dtbo;
      };

      formatter = lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ] (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
