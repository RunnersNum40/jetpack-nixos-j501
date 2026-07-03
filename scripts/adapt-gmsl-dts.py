#!/usr/bin/env python3
"""Adapt a Seeed GMSL camera overlay DTS from J401 (p3768) to J501 Mini (p3701).

Usage:
    python3 adapt-gmsl-dts.py <input.dts> <output.dts>
    curl -s <url> | python3 adapt-gmsl-dts.py - <output.dts>

The input is a DTS from Seeed-Studio/Linux_for_Tegra r36.5.0 targeting the J401
carrier board (JETSON_COMPATIBLE_P3768). The output is adapted for the J501 Mini
by replacing the compatible string and injecting inline GPIO macro definitions so
the DTS can be compiled without kernel header files.
"""
import re, sys

STUB_DEFINES = """\
/* J501 Mini adaptation: replace p3767 include with inline stubs */
#define JETSON_COMPATIBLE_P3768 "nvidia,p3737-0000+p3701-0004"

/* dt-bindings/gpio/gpio.h */
#define GPIO_ACTIVE_HIGH 0
#define GPIO_ACTIVE_LOW  1

/* dt-bindings/gpio/tegra234-gpio.h - main GPIO */
#define TEGRA234_MAIN_GPIO_PORT_G  6
#define TEGRA234_MAIN_GPIO_PORT_H  7
#define TEGRA234_MAIN_GPIO_PORT_Z  25
#define TEGRA234_MAIN_GPIO_PORT_AA 26
#define TEGRA234_MAIN_GPIO_PORT_AB 27
#define TEGRA234_MAIN_GPIO_PORT_AC 28
#define TEGRA234_MAIN_GPIO(port, offset) ((TEGRA234_MAIN_GPIO_PORT_##port * 8) + offset)

/* dt-bindings/gpio/tegra234-gpio.h - AON GPIO */
#define TEGRA234_AON_GPIO_PORT_AA 0
#define TEGRA234_AON_GPIO_PORT_BB 1
#define TEGRA234_AON_GPIO_PORT_CC 2
#define TEGRA234_AON_GPIO_PORT_DD 3
#define TEGRA234_AON_GPIO(port, offset) ((TEGRA234_AON_GPIO_PORT_##port * 8) + offset)
"""

src = sys.stdin.read() if sys.argv[1] == "-" else open(sys.argv[1]).read()
src = re.sub(r'#include <dt-bindings/tegra234-p3767-0000-common\.h>', STUB_DEFINES, src)
src = re.sub(r'overlay-name = "Seeed GMSL 1X4 3G"', 'overlay-name = "Seeed GMSL 1X4 3G (J501 Mini)"', src)
src = re.sub(r'overlay-name = "Seeed GMSL 1X4 6G"', 'overlay-name = "Seeed GMSL 1X4 6G (J501 Mini)"', src)
open(sys.argv[2], 'w').write(src)
