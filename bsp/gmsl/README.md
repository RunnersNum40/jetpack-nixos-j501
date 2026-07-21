# GMSL DTBO Files

Device tree binary overlays for the Seeed GMSL2 camera expansion board, plus
the vendored kernel drivers they need (`oot/`).

## Files

| File | Variant | Camera models |
|---|---|---|
| `tegra234-camera-seeed-gmsl-2x1x4-isx031.dtbo` | 6 Gbps, both FAKRA connectors | ISX031 + MAX9295A modules (e.g. Arducam 3MP ISX031 GMSL2) |
| `tegra234-camera-seeed-gmsl-1x4-3g.dtbo` | 3 Gbps | SG3S-ISX031C-GMSL2F |
| `tegra234-camera-seeed-gmsl-1x4-6g.dtbo` | 6 Gbps | SG2-AR0233C, SG2-IMX390C, SG8S-AR0820C |

The `.dts` source files alongside are the J501 Mini adaptations used to build
these DTBOs.

## Provenance

### 2x1x4-isx031

Adapted from `source/hardware/nvidia/t23x/nv-public/overlay/tegra234-seeed-gmsl2x1x4-6g-overlay.dts`
in [Seeed-Studio/Linux_for_Tegra r36.4.3](https://github.com/Seeed-Studio/Linux_for_Tegra/tree/r36.4.3)
by `adapt-2x1x4-isx031.py` (mechanical, re-runnable). Changes:

- dt-bindings includes replaced with inline stubs (GPIO port values from kernel
  v6.8 `dt-bindings/gpio/tegra234-gpio.h`; note port AC = 20, the binding is
  not alphabetically contiguous).
- `must_need_cmd = <1>` on all eight sensor nodes: the `nv_cam` driver then
  verifies the ISX031 chip-id at probe and writes the DT command tables on
  stream start. Seeed ships `<0>` because their SG3S modules auto-stream and
  are never written; ISX031+MAX9295A modules (Arducam) need the start command.
- Each serializer's `pins` node is wired as its pinctrl `default` state (inert
  upstream: nothing referenced it) and gains an `mfp4` group with
  `function = "rclkout"`, `maxim,rclkout-clock = <0>`. These modules derive the
  sensor's 24 MHz MCLK from serializer MFP4; without it the sensor never boots
  (no i2c, no video).

Boot-proven against Seeed's stock JetPack 6.2.1 image on a J501 Mini + AGX Orin
32GB with two Arducam ISX031 cameras (2026-07-16): both enumerate at probe and
stream 1920x1536 YUYV free-running with no manual configuration.

### 1x4-3g / 1x4-6g

Adapted from `source/hardware/nvidia/t23x/nv-public/overlay/tegra234-seeed-gmsl1x4-*-overlay.dts`
in [Seeed-Studio/Linux_for_Tegra r36.5.0](https://github.com/Seeed-Studio/Linux_for_Tegra/tree/r36.5.0).

Changes from the upstream r36.5.0 overlay (which targets the J401 carrier, `JETSON_COMPATIBLE_P3768`):

- `compatible` changed to `"nvidia,p3737-0000+p3701-0004"` (J501 Mini DTB root compatible)
- GPIO and I2C bus unchanged — the J501 Mini's `cam_i2c` alias also points to `i2c@3180000`
  and the 22-pin CSI connector uses the same GPIO assignments as the J401

Note: these predate the vendored driver stack, still bind the stock nvidia-oot
`max96712` register stub, and carry an incorrect inline `TEGRA234_MAIN_GPIO_PORT_AC 28`
(kernel binding is 20, so hogs on port AC never apply). Re-adapt them on top of
the maxim-serdes stack before relying on them.

## Regenerating

```bash
python3 adapt-2x1x4-isx031.py <upstream-dts> tegra234-camera-seeed-gmsl-2x1x4-isx031.dts
cpp -nostdinc -undef -x assembler-with-cpp -P tegra234-camera-seeed-gmsl-2x1x4-isx031.dts \
  | dtc -I dts -O dtb -@ -o tegra234-camera-seeed-gmsl-2x1x4-isx031.dtbo
```

Verify against the base DTB before shipping:

```bash
fdtoverlay -i ../tegra234-j501x-0000+p3701-0004-recomputer-mini.dtb \
  -o /dev/null tegra234-camera-seeed-gmsl-2x1x4-isx031.dtbo
```

## Kernel modules (`oot/`)

Vendored from Seeed-Studio/Linux_for_Tegra r36.4.3 `source/nvidia-oot/drivers`
(Seeed has not published r39 BSP sources; their JetPack 7.2 MFI image ships no
camera modules at all):

- `maxim-serdes/` — Seeed's GMSL2 framework (`max_serdes_all`), `max96724`
  deserializer (also binds `maxim,max96712` silicon), `max96717` serializer
  (also binds `maxim,max9295a` — the ISX031 modules' chip), `max9296a`,
  `max_aggregator`. Backported-from-mainline code. The required `i2c-atr`
  helper is bundled alongside (verbatim mainline v6.8 copy) because
  `CONFIG_I2C_ATR` is a promptless Kconfig symbol — only reachable via in-tree
  `select`, so it cannot be enabled in the tegra kernel config.
- `nv_cam.c` — generic tegracam YUV sensor subdev (`nv,nv-cam`), driven
  entirely by DT command tables.
- `obc_cam_sync.c/.h` — nv_cam's frame-sync generator dependency (dormant for
  free-running cameras).

`modules/gmsl.nix` injects these into the `l4t-oot-modules` build for the
`2x1x4-isx031` variant.

## Adding another camera model

The driver stack is camera-agnostic: the serdes drivers handle any GMSL2
module built on a MAX9295A or MAX96717(F) serializer, and `nv_cam` is driven
entirely by device tree — chip-id verification registers, per-mode properties,
and the i2c command tables all live in the overlay, so a new sensor needs no C
code. To add a model:

1. Start from `tegra234-camera-seeed-gmsl-2x1x4-isx031.dts` (or re-run the
   adapt script against a different upstream Seeed overlay) and change per
   sensor node: `nv,chip-id-regs/-masks/-vals`, the `mode*` properties
   (resolution, pixel format, rates), and the `nv,mode-common-cmd` /
   `nv,start-stream-cmd` / `nv,stop-stream-cmd` tables from the sensor
   datasheet. Set `must_need_cmd = <1>` unless the module auto-streams on
   power-up (Seeed's SG series does; most others don't).
2. Match the serializer wiring to the module datasheet: `compatible`
   (`maxim,max9295a` or `maxim,max96717`), and the pinctrl `pins` groups —
   keep the `rclkout` group only if the module derives its sensor MCLK from a
   serializer MFP (the Arducam ISX031 uses MFP4), and adjust the
   pwdn/reset/fsync MFP assignments.
3. Add the variant to `variantDtboFile` and `variantSubdevFormat` in
   `modules/gmsl.nix` (the format string is the media-bus code + resolution
   the sensor emits, applied to every ser/des channel subdev at boot).

If the sensor never streams, check in order: serializer RCLK/MCLK (sensor
absent from i2c entirely means no clock or held in reset), chip-id read
through the muxed adapter, then PCLKDET (serializer reg 0x102 bit 7) after the
start command — it flips to 1 the moment the sensor emits pixels.
