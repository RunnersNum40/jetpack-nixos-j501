# GMSL Camera Support

Device tree source for the Seeed GMSL2 camera expansion board, plus the
vendored kernel drivers it needs (`oot/`).

## Files

| File | Topology | Camera models |
|---|---|---|
| `tegra234-camera-seeed-gmsl-2x1x4-isx031.dts` | 6 Gbps, both FAKRA connectors | ISX031 + MAX9295A modules (e.g. Arducam 3MP ISX031 GMSL2) |

Nix builds the DTBO from this source when the module is enabled.

## Provenance

Adapted from `source/hardware/nvidia/t23x/nv-public/overlay/tegra234-seeed-gmsl2x1x4-6g-overlay.dts`
in [Seeed-Studio/Linux_for_Tegra at `0b8eade`](https://github.com/Seeed-Studio/Linux_for_Tegra/tree/0b8eadeacd3a09ae67e744cac6d525b2663dce54)
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

Vendored from Seeed-Studio/Linux_for_Tegra commit
[`0b8eade`](https://github.com/Seeed-Studio/Linux_for_Tegra/tree/0b8eadeacd3a09ae67e744cac6d525b2663dce54)
`source/nvidia-oot/drivers`
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

`modules/gmsl.nix` injects these into the `nvidia-oot-modules` build.

### r39 / kernel 6.8 adaptation

The vendored r36.4.3 drivers are backported-mainline code, so the compile port
to kernel 6.8 is mechanical. r39's camera framework (nvidia-oot) needs four
patches, applied via `modules/gmsl.nix` `postPatch`:

- `sensor_common-atr-bus.patch` — tolerate sensors on i2c-atr virtual buses,
  which have no Tegra i2c-controller MMIO parent (stock r39 hard-fails there).
- `tegracam-dt-frmfmt.patch` — `tegracam_device_register` NULL-derefs on a
  DT-table sensor with no static `frmfmt_table`; build it from the DT modes.
- `vi-channel-subdev-walk.patch` — r39's VI upstream walk assumes each subdev's
  sink pad is at `source_index - 1`; serdes channel subdevs order source-first,
  truncating the chain at the deserializer so the VI never learns the sensor.
- `csi-mipi-clock-serdes.patch` — the CSI channel's `s_data` is left unlinked
  for serdes topologies, so NVCSI auto-tuned `T_HS_SETTLE` from a 102 MHz
  default instead of the real lane rate (D-PHY SOT-error storm, no frames);
  recover the MIPI clock from the VI channel's resolved sensor.

The vendored drivers also carry serdes-specific behaviour the stock r39 path
lacks: `i2c-atr` passes unmapped client addresses through untranslated (GMSL
parts self-address on the link), and `nv_cam` returns `-EPROBE_DEFER` until
GMSL link training settles, then runs `power_on` plus a NOR-boot settle at
stream start (r39's VI never calls `s_power` on a sensor behind a serdes).

The files under `oot/` preserve their GPL-2.0 SPDX identifiers. Their local
kernel 6.8 and GMSL adaptations are visible in this branch's Git history.

Proven end-to-end on NixOS / JetPack 7 (L4T r39.2, kernel 6.8) with two Arducam
ISX031 modules: `/dev/video0` streams 1920x1536 YUYV, fully driver-managed.

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
3. Extend `modules/gmsl.nix` to select the new overlay and media-bus format.
   The format is applied to every ser/des channel subdev at boot.

If the sensor never streams, check in order: serializer RCLK/MCLK (sensor
absent from i2c entirely means no clock or held in reset), chip-id read
through the muxed adapter, then PCLKDET (serializer reg 0x102 bit 7) after the
start command — it flips to 1 the moment the sensor emits pixels.

If PCLKDET is set (sensor emitting) but the VI still times out with no frames,
enable the `tegra_rtcpu/rtcpu_nvcsi_intr` ftrace event during a capture. A
storm of `PHY_INTR` SOT-sync errors with zero CAPTURE SOF/EOF events means
NVCSI cannot lock the incoming lanes — a D-PHY timing/rate mismatch. Compare
the RCE's reported "MIPI clock rate" (dmesg) against the real lane rate; a
default like 102 MHz there points at an unlinked CSI-channel `s_data`
(the `csi-mipi-clock-serdes.patch` case).

## Deployment

`hardware.j501.gmsl` is disabled by default. Enabling it wires the DTBO into the
flash image via `flashScriptOverrides`, so the overlay reaches the board either
by a full reflash **or**, on systems with
`hardware.nvidia-jetpack.firmware.autoUpdate = true`, by the UEFI capsule applied
on `nixos-rebuild switch` (the device tree updates on the next boot). The kernel
modules and the `gmsl-subdev-formats` service install with a normal switch, but
the cameras do not probe until that DTBO update lands — an in-place switch with
neither the capsule nor a reflash leaves GMSL inactive.

## Known limitations (inherited upstream)

The vendored Seeed drivers carry a few pre-existing robustness gaps in their
error/teardown paths. They do not fire on a statically-configured board (no
hot-unplug; probe runs to completion), so they are documented rather than patched
to keep the vendored diff minimal — worth upstreaming to Seeed:

- `max_ser_probe()`/`max_des_probe()` return directly from later failures after
  creating the ATR and registering its bus notifier, without deleting the ATR or
  unwinding partial V4L2 registration (stale references after a failed probe).
- Software state is committed before the hardware write and not rolled back on
  failure: pipe/stream `active` (a retried STREAMON/STREAMOFF then exits early)
  and the ATR i2c-translation state on attach (`num_i2c_xlates` /
  `ser_xlate_enabled`, so a transient attach error leaves that channel bound but
  unprogrammed with no retry).
- `nv_cam` exposes exposure and frame-rate controls whose callbacks return
  success without programming anything (the ISX031's on-board ISP free-runs, so
  there is nothing to set); applications are told a change took effect when it
  did not. Gain is guarded (returns `-EINVAL`); the others are left as-is
  pending a decision on dropping the controls vs. failing them.
- `nv_cam_parse_dt()` computes `-EPROBE_DEFER` for missing serializer GPIOs but
  returns the pdata unconditionally, discarding the deferral. It does not bite
  here because probe is already deferred until the serializer is up (chip-id
  retry / link training); honouring it would need the tegracam framework to
  accept an `ERR_PTR` from `parse_dt`.
