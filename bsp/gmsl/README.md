# GMSL DTBO Files

Device tree binary overlays for the Seeed GMSL2 camera expansion board.

## Files

| File | Variant | Camera models |
|---|---|---|
| `tegra234-camera-seeed-gmsl-1x4-3g.dtbo` | 3 Gbps | SG3S-ISX031C-GMSL2F |
| `tegra234-camera-seeed-gmsl-1x4-6g.dtbo` | 6 Gbps | SG2-AR0233C, SG2-IMX390C, SG8S-AR0820C |

The `.dts` source files alongside are the J501 Mini adaptations used to build these DTBOs.

## Provenance

Adapted from `source/hardware/nvidia/t23x/nv-public/overlay/tegra234-seeed-gmsl1x4-*-overlay.dts`
in [Seeed-Studio/Linux_for_Tegra r36.5.0](https://github.com/Seeed-Studio/Linux_for_Tegra/tree/r36.5.0).

Changes from the upstream r36.5.0 overlay (which targets the J401 carrier, `JETSON_COMPATIBLE_P3768`):

- `compatible` changed to `"nvidia,p3737-0000+p3701-0004"` (J501 Mini DTB root compatible)
- GPIO and I2C bus unchanged — the J501 Mini's `cam_i2c` alias also points to `i2c@3180000`
  and the 22-pin CSI connector uses the same GPIO assignments as the J401

## Regenerating

Download the upstream DTS from Seeed-Studio/Linux_for_Tegra r36.5.0 and apply two edits:

1. Replace `#include <dt-bindings/tegra234-p3767-0000-common.h>` with inline definitions for
   `JETSON_COMPATIBLE_P3768`, `GPIO_ACTIVE_HIGH/LOW`, `TEGRA234_MAIN_GPIO*`, and
   `TEGRA234_AON_GPIO*` (needed because J501 BSP headers are not available at compile time).
2. Append `(J501 Mini)` to the `overlay-name` string.

Then compile:

```bash
cpp -nostdinc -undef -x assembler-with-cpp -P tegra234-camera-seeed-gmsl-1x4-3g.dts \
  | dtc -I dts -O dtb -@ -o tegra234-camera-seeed-gmsl-1x4-3g.dtbo
```

## Kernel modules

Driver status as of L4T r39.2.0 / JetPack 7.2 (investigated 2026-07-03):

**MAX96712 deserializer** — driver present in NVIDIA's `nvidia-oot` (built as part of
`l4t-oot-modules` in jetpack-nixos) and binds to `compatible = "nvidia,max96712"`. The
DTBOs here use that string (corrected from Seeed's upstream `"maxim,max96712"`).

**MAX96717 serializer** — no driver exists in nvidia-oot, the mainline 6.8 kernel, or
Seeed's Ubuntu MFI image (`mfi_recomputer-mini-agx-orin-j501x-32g-7.2.0-39.2.0`). The MFI
ships only 22 kernel modules, none camera-related. Seeed has not published r39 BSP sources.

See the comment in `modules/gmsl.nix` for next steps once a MAX96717 driver becomes available.
