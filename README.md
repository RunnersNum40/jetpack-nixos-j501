# jetpack-nixos-j501

NixOS support for Seeed reComputer J501 Mini carrier boards (NVIDIA Jetson AGX Orin).

Built as a downstream extension of [anduril/jetpack-nixos](https://github.com/anduril/jetpack-nixos).

Binary cache: `https://ted.cachix.org` (public key: `ted.cachix.org-1:nmMqGqqYi74uo0sMW7Gt0BY2qvaaFG6lOfibBpcxhFw=`)

## Supported hardware

| Carrier board | Module | JetPack | Status |
|---|---|---|---|
| reComputer J501 Mini | AGX Orin 32GB | 7.2 (L4T r39.2) | supported |
| reComputer J501 Mini | AGX Orin 64GB | 7.2 (L4T r39.2) | supported |

Other reComputer J\*01 boards (J401 Mini, J202, J101) are planned pending more hardware. Contributions welcome. If you'd like me to support your board and are willing to provide one for testing, please reach out.

## Prerequisites

- Linux x86\_64 host (any distribution with Nix installed)
- Nix with flakes enabled
- The J501 board must be **unfused** (dev mode) for full QSPI reflash via RCM.
  Production-fused boards with Seeed's SBK cannot reflash the QSPI bootloader
  chain this way; a rootfs-only path is not yet implemented.

## First-time setup: compute the Seeed BSP hash

The Seeed Linux\_for\_Tegra BSP source is fetched from GitHub. Before building,
compute the hash for the pinned commit:

```bash
nix-shell -p nix-prefetch-github --run \
  'nix-prefetch-github Seeed-Studio Linux_for_Tegra \
     --rev 646f403d13a285cc6f92287a4236666a0ea85738'
```

Copy the resulting `sha256` value and update `pkgs/seeed-bsp/default.nix`:

```nix
sha256 = "sha256-<your-hash-here>";
```

## Flashing NixOS

### 1. Build the flash script

```bash
nix build github:RunnersNum40/jetpack-nixos-j501#flash-j501-agx-orin-32gb
```

Or from a local checkout:

```bash
nix build .#flash-j501-agx-orin-32gb
```

### 2. Enter force recovery mode

1. With the board powered off, press and hold the **REC** button.
2. Apply power (XT30 connector, 19–48V).
3. Release the **REC** button.
4. Connect the **USB 3.0 Type-C** (recovery/debug) port to your host.

Verify the board is in recovery mode:

```bash
lsusb | grep -i nvidia
# Expected: 0955:7223 NVidia Corp  (AGX Orin 32GB)
# Expected: 0955:7023 NVidia Corp  (AGX Orin 64GB)
```

### 3. Run the flash script

```bash
sudo ./result/flash-j501-agx-orin-32gb
```

This flashes only the QSPI bootloader chain (MB1, BPMP, UEFI, OP-TEE, etc.).
It does **not** touch the NVMe SSD. The rootfs is installed separately after
first boot.

### 4. Install NixOS on NVMe

After the QSPI flash completes, the board boots into UEFI. Build the J501
installer ISO and write it to a USB drive:

```bash
nix build .#iso-installer-j501
sudo dd if=./result/iso/nixos-*.iso of=/dev/sdX bs=4M oflag=sync status=progress
```

Insert the USB drive into the board and boot from it via the UEFI Boot Manager.
Once the installer is up, SSH in and deploy.

```bash
nix run .#deploy-j501 -- <board-ip>
```

Or call `nixos-anywhere` directly against the running installer:

```bash
nix run nixpkgs#nixos-anywhere -- \
  --flake .#board-j501-agx-orin-32gb \
  --target-host root@<board-ip>
```

### Updating or reinstalling an existing system

> **Warning — do not run `nixos-anywhere` against a Jetson that is already
> running NixOS/L4T.** When the target is not an installer, `nixos-anywhere`
> kexecs into the generic `nixos-images` aarch64 kernel, which has no Tegra
> device tree or firmware init and cannot boot on Tegra234. The board
> silently cold-reboots back into the existing system, and the install then
> fails.

- **Update in place**: use `nixos-rebuild`, which does
  not kexec:

  ```bash
  nixos-rebuild switch \
    --flake .#board-j501-agx-orin-32gb \
    --target-host root@<board-ip> --sudo
  ```

- **Wipe and reinstall:** re-boot the J501 installer ISO and repeat the
  `deploy-j501` step above. `disko` repartitions the NVMe from the installer
  environment (no kexec).

## Using as a NixOS module

Add to your flake inputs:

```nix
jetpack-nixos-j501 = {
  url = "github:RunnersNum40/jetpack-nixos-j501";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Import the module in your NixOS configuration (it automatically includes the
upstream `anduril/jetpack-nixos` module):

```nix
imports = [ jetpack-nixos-j501.nixosModules.default ];

hardware.nvidia-jetpack = {
  enable = true;
  som = "orin-agx";
  carrierBoard = "recomputer-j501-mini";
  majorVersion = "7";
};
```

Enable the binary cache to avoid rebuilding large packages:

```nix
nix.settings = {
  substituters = [ "https://ted.cachix.org" ];
  trusted-public-keys = [
    "ted.cachix.org-1:nmMqGqqYi74uo0sMW7Gt0BY2qvaaFG6lOfibBpcxhFw="
  ];
};
```

## Board-specific notes

### Storage

The flash script flashes QSPI only (`flash_t234_qspi.xml`). The AGX Orin
module's onboard eMMC is left untouched. The NVMe SSD (M.2 Key M) is the
intended NixOS rootfs target.

### Ethernet

The J501 Mini has one 10GbE and one 1GbE port. The 10GbE is enabled via
`ODMDATA=gbe-uphy-config-22,...,gbe0-enable-10g` in the Seeed board config.
Both ports are available after boot with no additional configuration.

### CAN

Two CAN/CAN-FD interfaces (`can0`, `can1`) on GH 1.25 connectors. Termination
resistors are software-controlled via GPIO (PAA.04 and PAA.07 on gpiochip1).

### UART / GPO

The 6-pin GH 1.25 JST header defaults to GPO. Switching to UART (`/dev/ttyTHS1`)
requires a device tree overlay pointing to a UART-enabled DTB. Seeed documents
this in their wiki.

### Production-fused boards

If your board has been production-fused with Seeed's SBK key, the QSPI
bootloader chain is signed and cannot be replaced without Seeed's private key.
In this case you would need a rootfs-only installation path that preserves the
existing bootloader. This is not yet implemented.

## Development

```bash
# Format all Nix files
nix fmt

# Evaluate the flash script derivation (does not build)
nix eval .#packages.x86_64-linux.flash-j501-agx-orin-32gb

# Build
nix build .#flash-j501-agx-orin-32gb --print-build-logs
```

## License

MIT. See [LICENSE](LICENSE).

The Seeed Linux\_for\_Tegra BSP files fetched at build time are governed by
NVIDIA's BSD-3-Clause license (configuration files) and GPL-2 (kernel device
trees). NVIDIA firmware blobs fetched via `anduril/jetpack-nixos` are governed
by NVIDIA's embedded software license; they are not redistributed by this
project.
