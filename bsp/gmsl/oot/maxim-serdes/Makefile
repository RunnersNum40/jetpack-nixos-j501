# SPDX-License-Identifier: GPL-2.0
max_serdes_all-objs := max_ser.o max_des.o max_serdes.o

obj-m += max_serdes_all.o
obj-m += max_aggregator.o
obj-m += max96717.o
obj-m += max96724.o
obj-m += max9296a.o

# Mainline v6.8 i2c-atr, bundled because CONFIG_I2C_ATR is a promptless Kconfig
# symbol (only reachable via in-tree `select`) and the tegra kernel doesn't
# build it.
obj-m += i2c-atr.o
