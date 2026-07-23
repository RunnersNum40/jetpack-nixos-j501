{
  buildPackages,
  dtc,
  runCommand,
}:

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
      ${./tegra234-camera-seeed-gmsl-2x1x4-isx031.dts} \
      | dtc -I dts -O dtb -@ \
          -o "$out/tegra234-camera-seeed-gmsl-2x1x4-isx031.dtbo"
  ''
