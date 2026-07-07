# jetpack-nixos-j501

NixOS support for Seeed reComputer J501 Mini carrier boards (NVIDIA Jetson AGX Orin).

Built as a downstream extension of [anduril/jetpack-nixos](https://github.com/anduril/jetpack-nixos) using information from the [Seeed wiki](https://wiki.seeedstudio.com/recomputer_j501_mini_getting_started/).

Binary cache: `https://ted.cachix.org` (public key: `ted.cachix.org-1:nmMqGqqYi74uo0sMW7Gt0BY2qvaaFG6lOfibBpcxhFw=`)

## Supported hardware

| Carrier board | Module | JetPack | Status |
|---|---|---|---|
| reComputer J501 Mini | AGX Orin 32GB | 7.2 (L4T r39.2) | supported |
| reComputer J501 Mini | AGX Orin 64GB | 7.2 (L4T r39.2) | supported |

A single build (`flash-j501-agx-orin` / `j501-agx-orin`) covers both the
32GB (SKU 0004) and 64GB (SKU 0005) modules: the flash script bundles both
firmware variants and auto-detects the connected module's SKU at flash time.

Contributions welcome for other reComputer J\*01 boards.

## Prerequisites

- Linux x86\_64 host (any distribution with Nix installed)
- Nix with flakes enabled
- The J501 board must be **unfused** (dev mode) for full QSPI reflash via RCM.
  Production-fused boards with Seeed's SBK cannot reflash the QSPI bootloader
  chain this way; a rootfs-only path is not yet implemented.

## Flashing NixOS

### 1. Build the flash script

```bash
nix build github:RunnersNum40/jetpack-nixos-j501#flash-j501-agx-orin
```

Or from a local checkout:

```bash
nix build .#flash-j501-agx-orin
```

### 2. Enter force recovery mode

1. With the board powered off, press and hold the **REC** button.
2. Apply power (XT30 connector, 19-48V).
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
sudo ./result/bin/initrd-flash-orin-agx-recomputer-j501-mini
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
  --flake .#j501-agx-orin \
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
    --flake .#j501-agx-orin \
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

Enable the binary cache to avoid rebuilding large packages:

```nix
nix.settings = {
  substituters = [ "https://ted.cachix.org" ];
  trusted-public-keys = [
    "ted.cachix.org-1:nmMqGqqYi74uo0sMW7Gt0BY2qvaaFG6lOfibBpcxhFw="
  ];
};
```

Import the module in your NixOS configuration:

```nix
imports = [ jetpack-nixos-j501.nixosModules.default ];

hardware.nvidia-jetpack = {
  enable = true;
  som = "orin-agx";
  carrierBoard = "recomputer-j501-mini";
  majorVersion = "7";
};
```

## Board-specific notes

Every interface below is enabled by the flashed device tree and stock drivers
(mainline `defconfig` plus the `nvidia-oot` modules `anduril/jetpack-nixos`
already builds). See the
[Seeed wiki](https://wiki.seeedstudio.com/recomputer_j501_mini_getting_started/)
for wiring diagrams and per-interface examples.

| Interface | Device / sysfs | Out of the box | Notes |
|---|---|---|---|
| RGB LED | `/sys/class/leds/on-board:{red,green,blue}` | yes | `gpio-leds` |
| Fan | `pwm-fan` via `nvfancontrol` | yes | fan control service enabled by default |
| CAN0 / CAN1 | `can0`, `can1` | yes | CAN-FD; `mttcan`; termination on gpiochip1 lines 4/7 |
| GPI / GPO | `gpiochip0` (libgpiod: `gpioget`/`gpioset`) | yes | 6-pin header defaults to GPO |
| UART (6-pin) | `/dev/ttyTHS1` | no | shares the GPO header; needs MB1 pinmux change (see below) |
| RS485 | `/dev/ttyTHS4` | yes | enable transceiver via GPIO before use (Maximum baud rate of 1 Mbps in my testing) |
| I2S | ALSA card `APE` | yes (hardware) | route with `jetson-io` / `amixer` |
| RTC | `/sys/class/rtc/rtc0` (PMIC), `rtc1` (Tegra) | yes | needs coin-cell battery |
| M.2 Key E | PCIe + USB | card-dependent | Wi-Fi/BT — see below |

### Storage

The flash script flashes QSPI only (`flash_t234_qspi.xml`). The AGX Orin
module's onboard eMMC is left untouched. An NVMe SSD (M.2 Key M) is the
intended NixOS rootfs target.

### Ethernet

The J501 Mini has one 10GbE and one 1GbE port. The 10GbE is enabled via
`ODMDATA=gbe-uphy-config-22,...,gbe0-enable-10g` in the Seeed board config.
Both ports are available after boot with no additional configuration.

### CAN

Two CAN/CAN-FD interfaces (`can0`, `can1`) on GH 1.25 connectors. Termination
resistors are software-controlled via GPIO (PAA.04 and PAA.07 on gpiochip1).

### UART / GPO

The 6-pin GH 1.25 JST header is shared between GPO and UART (`/dev/ttyTHS1`,
`uarta` / `serial@3100000`) and defaults to GPO. Switching it to UART is **not**
a kernel device-tree overlay: the pin function is set at the MB1 BCT pinmux
stage (QSPI firmware), and neither the flashed kernel DTB nor Seeed's
wiki-distributed "UART" DTB carries a UART pin mux for this header (the kernel
pinmux node exposes only `rsvd1`/`xusb` functions). Enabling UART therefore
requires an MB1 pinmux override (`PINMUX_CONFIG`), which depends on Seeed's
board-specific pinmux DTSI — not published for L4T r39. This project currently
ships the AGX Orin devkit pinmux approximation, so the header is GPO-only for
now. RS485 (`/dev/ttyTHS4`, `uarte`) is unaffected and works today.

### M.2 Key E (Wi-Fi / Bluetooth)

The slot is wired to PCIe + USB and the wireless stack (`cfg80211`, `mac80211`,
`BT`, `BT_HCIBTUSB`, `rfkill`) is compiled in unconditionally. Realtek
(`rtl8822ce`, `rtl8852ce`) and Broadcom (`bcmdhd`) card drivers ship in
`nvidia-oot` and load automatically. Intel cards (AX200/AX210, `iwlwifi`) need
the driver added by the user:

```nix
boot.kernelPatches = [{
  name = "iwlwifi";
  patch = null;
  structuredExtraConfig = with lib.kernel; {
    IWLWIFI = module;
    IWLMVM = module;
  };
}];
hardware.enableRedistributableFirmware = true;
```

Any card also needs its firmware (`hardware.enableRedistributableFirmware` or a
targeted `hardware.firmware` entry) and a network stack
(`networking.networkmanager.enable`).

### Production-fused boards

If your board has been production-fused with Seeed's SBK key, the QSPI
bootloader chain is signed and cannot be replaced without Seeed's private key.
In this case you would need a rootfs-only installation path that preserves the
existing bootloader. This is not yet implemented.

## Development

```bash
# Format all Nix files
nix fmt

# Build
nix build .#flash-j501-agx-orin --print-build-logs
```

## License

MIT. See [LICENSE](LICENSE).

The Seeed Linux\_for\_Tegra BSP files fetched at build time are governed by
NVIDIA's BSD-3-Clause license (configuration files) and GPL-2 (kernel device
trees). NVIDIA firmware blobs fetched via `anduril/jetpack-nixos` are governed
by NVIDIA's embedded software license; they are not redistributed by this
project.
