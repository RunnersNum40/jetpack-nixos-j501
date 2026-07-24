#!/usr/bin/env python3
"""Adapt Seeed r36.4.3 gmsl2x1x4-6g overlay for J501 Mini + Arducam ISX031.

Mechanical transform of the upstream DTS:
  1. Replace dt-bindings includes with inline stubs (values from kernel v6.8
     include/dt-bindings/gpio/tegra234-gpio.h; JETSON_COMPATIBLE from the
     boot-proven stock dtbo's compatible list).
  2. Rename overlay for the ISX031 variant.
  3. must_need_cmd 0 -> 1 on all 8 sensor nodes (nv_cam then verifies chip-id
     and writes the DT command tables).
  4. Wire each serializer's inert `pins` node as its pinctrl default state and
     add an mfp4 rclkout group (24 MHz sensor MCLK -- Arducam modules derive
     the sensor clock from serializer MFP4).
  5. Drop the copied 1080p/4K modes; the ISX031 emits only mode0 (1920x1536).
  6. Drop the unused obc_cam_sync frame-sync generator node.
  7. Add serdes_pix_clk_hz to every mode (r39 sensor_common reads it directly
     and defaults to 0 when absent, collapsing the CSI lane rate).
  8. Normalize I2C unit addresses and route the second camera bank to CSI-G.
"""

import re
import sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()

# includes -> inline stubs
includes = """#include <dt-bindings/clock/tegra234-clock.h>
#include <dt-bindings/gpio/tegra234-gpio.h>
#include <dt-bindings/tegra234-p3737-0000+p3701-0000.h>"""
stubs = """/* J501 Mini adaptation: BSP dt-bindings headers are unavailable at compile
 * time; inline the macros actually used. GPIO port numbers from kernel v6.8
 * include/dt-bindings/gpio/tegra234-gpio.h (note: port AC is 20 -- the
 * bindings are not alphabetically contiguous). */
#define JETSON_COMPATIBLE "nvidia,p3737-0000+p3701-0000", "nvidia,p3737-0000+p3701-0004", "nvidia,p3737-0000+p3701-0005", "nvidia,p3737-0000+p3701-0008"

#define GPIO_ACTIVE_HIGH 0
#define GPIO_ACTIVE_LOW  1

#define TEGRA234_MAIN_GPIO_PORT_A   0
#define TEGRA234_MAIN_GPIO_PORT_H   7
#define TEGRA234_MAIN_GPIO_PORT_Q  15
#define TEGRA234_MAIN_GPIO_PORT_R  16
#define TEGRA234_MAIN_GPIO_PORT_AC 20
#define TEGRA234_MAIN_GPIO(port, offset) ((TEGRA234_MAIN_GPIO_PORT_##port * 8) + offset)

#define TEGRA234_AON_GPIO_PORT_BB 1
#define TEGRA234_AON_GPIO_PORT_CC 2
#define TEGRA234_AON_GPIO(port, offset) ((TEGRA234_AON_GPIO_PORT_##port * 8) + offset)"""
assert includes in text, "include block not found"
text = text.replace(includes, stubs, 1)

# overlay name
old_name = 'overlay-name = "Seeed GMSL 2X1X4 6G";'
assert old_name in text
text = text.replace(
    old_name, 'overlay-name = "Seeed GMSL 2X1X4 ISX031 (J501 Mini)";', 1
)

# The ISX031 free-runs; drop Seeed's unused external frame-sync generator.
obc_sync = re.compile(r"\n\t\t\tobc_cam_sync \{.*?\n\t\t\t\};\n", re.DOTALL)
text, n = obc_sync.subn("", text)
assert n == 1, f"obc_cam_sync blocks: {n}"

# must_need_cmd
n = text.count("must_need_cmd = <0x00>;")
assert n == 8, f"must_need_cmd count: {n}"
text = text.replace("must_need_cmd = <0x00>;", "must_need_cmd = <0x01>;")

# serdes_pix_clk_hz: r39's sensor_common reads this property to populate
# serdes_pixel_clock; r36 derived it from serdes_link_freq but r39 defaults to
# 0 when it is absent, which collapses the computed CSI lane rate so the
# serializer never locks to the (free-running) sensor's MIPI output. 625 MHz =
# serdes_link_freq / 2, matching the value r36 computed on the working stock.
n = len(re.findall(r'serdes_link_freq = "1250000000";', text))
assert n == 24, f"serdes_link_freq count: {n}"
text = re.sub(
    r'(?P<indent>\t+)serdes_link_freq = "1250000000";',
    lambda m: (
        m.group(0) + "\n" + m.group("indent") + 'serdes_pix_clk_hz = "625000000";'
    ),
    text,
)


# ISX031 modules emit only mode0 (1920x1536). The upstream template carries
# copied 1080p/4K modes with empty nv,mode-cmd that the sensor never produces
# (and nv_cam runs no mode commands anyway), so advertising them lets userspace
# select a stream that never arrives. Keep only mode0. Each modeN block is flat
# (properties only, no nested braces).
mode_block = re.compile(r"\n[\t ]*mode[12] \{.*?\n[\t ]*\};", re.DOTALL)
n = len(mode_block.findall(text))
assert n == 16, f"mode1/2 blocks: {n}"
text = mode_block.sub("", text)

# dtc unit names omit the C-style 0x prefix.
for old, new, expected in (
    ("gmsl-deserializer0@0x29", "gmsl-deserializer0@29", 1),
    ("gmsl-deserializer1@0x29", "gmsl-deserializer1@29", 1),
    ("gmsl-serializer@0x40", "gmsl-serializer@40", 8),
    ("ox03a@0x1a", "ox03a@1a", 8),
):
    count = text.count(old)
    assert count == expected, f"{old} count: {count}"
    text = text.replace(old, new)


# pinctrl consumer props on each ser node, after its i2c-alias-pool line
def add_pinctrl(m):
    idx = m.group("idx")
    indent = m.group("indent")
    return (
        m.group(0)
        + f'\n{indent}pinctrl-names = "default";'
        + f"\n{indent}pinctrl-0 = <&ser_{idx}_pins>;"
    )


ser_head = re.compile(
    r"(?P<indent>\t+)gpio-ranges = <&ser_(?P<idx>[0-7]) 0 0 11>;\n"
    r"(?P=indent)i2c-alias-pool = <0x[0-9a-f]+>;",
)
text, n = ser_head.subn(lambda m: add_pinctrl(m), text)
assert n == 8, f"pinctrl insertions: {n}"


# label each pins node and add the mfp4 rclkout group
def add_rclk(m):
    idx = m.group("idx")
    outer = m.group("outer")
    inner = m.group("inner")
    return (
        f"{outer}ser_{idx}_pins: pins {{\n"
        f"{inner}\n"
        f"{inner}ser_{idx}_mfp4_rclk {{\n"
        f'{inner}\tpins = "mfp4";\n'
        f'{inner}\tfunction = "rclkout";\n'
        f"{inner}\tmaxim,rclkout-clock = <0>;\n"
        f"{inner}}};\n"
        f"{inner}\n"
        f"{inner}ser_{idx}_mfp0_pwdn {{"
    )


pins_head = re.compile(
    r"(?P<outer>\t+)pins \{\n"
    r"(?P<inner>\t+)\n"
    r"(?P=inner)ser_(?P<idx>[0-7])_mfp0_pwdn \{",
)
text, n = pins_head.subn(add_rclk, text)
assert n == 8, f"rclk insertions: {n}"

# frame sync (optional, cpp-gated): each des can run its internal FSYNC
# generator, every sensor following the pulse forwarded to its serializer's
# MFP7.
# The upstream sensor nodes claim MFP7 as reset-gpios, double-booking the
# FSYNC pin: every nv_cam power transition then drives the sensor's FSYNC
# input as a GPIO and clobbers the fsync RX arming. The sensor's real reset
# is MFP0 (pwdn-gpios, 500 ms settle), so drop the bogus reset-gpios.
fsync_reset = re.compile(r"\n\t+reset-gpios = <&ser_[0-7] 7 GPIO_ACTIVE_HIGH>;")
text, n = fsync_reset.subn("", text)
assert n == 8, f"reset-gpios removals: {n}"

# park MFP7 low: the ISX031 samples FSYNC at NOR boot and only free-runs
# (streams at all) when the pin is low; arming to RX happens mid-stream
fsync_park = re.compile(
    r'(ser_[0-7]_mfp7_fsync \{\n(?P<i>\t+)pins = "mfp7";\n'
    r'(?P=i)function = "gpio";\n(?P=i))output-high;'
)
text, n = fsync_park.subn(r"\g<1>output-low;", text)
assert n == 8, f"mfp7 park rewrites: {n}"

# cpp-gated so one DTS serves any deployment: FSYNC_HZ=0 (the default in
# dtbo.nix) omits both properties and the cameras free-run
fsync_des = re.compile(r"(?P<indent>\t+)fsync_mfp_in = <2>;")
text, n = fsync_des.subn(
    lambda m: (
        m.group(0)
        + f"\n#if FSYNC_HZ\n{m.group('indent')}maxim,fsync-hz = <FSYNC_HZ>;\n#endif"
    ),
    text,
)
assert n == 2, f"fsync-hz insertions: {n}"

fsync_cam = re.compile(r'(?P<indent>\t+)compatible = "nv,nv-cam";')
text, n = fsync_cam.subn(
    lambda m: (
        m.group(0) + f"\n#if FSYNC_HZ\n{m.group('indent')}nv,fsync-type = <1>;\n#endif"
    ),
    text,
)
assert n == 8, f"fsync-type insertions: {n}"

open(dst, "w").write(text.rstrip() + "\n")
print(f"adapted -> {dst}")
