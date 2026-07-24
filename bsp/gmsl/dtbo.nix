{
  buildPackages,
  dtc,
  runCommand,
  # 0 disables frame sync (cameras free-run); 2-120 runs each deserializer's
  # internal FSYNC generator at that rate and slaves every sensor to it.
  fsyncHz ? 0,
}:

assert fsyncHz == 0 || (fsyncHz >= 2 && fsyncHz <= 120);

runCommand "j501-gmsl-isx031-dtbo"
  {
    nativeBuildInputs = [
      dtc
      buildPackages.stdenv.cc
    ];
  }
  ''
    mkdir -p "$out"
    cpp -nostdinc -undef -x assembler-with-cpp -P \
      -DFSYNC_HZ=${toString fsyncHz} \
      ${./tegra234-camera-seeed-gmsl-2x1x4-isx031.dts} \
      | dtc -I dts -O dtb -@ \
          -o "$out/tegra234-camera-seeed-gmsl-2x1x4-isx031.dtbo"
  ''
