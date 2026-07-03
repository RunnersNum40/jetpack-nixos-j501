{ ... }:
{
  hardware.nvidia-jetpack = {
    enable = true;
    som = "orin-agx";
    carrierBoard = "recomputer-j501-mini";
    majorVersion = "7";
    # Cross-compilation from x86_64 is not supported for CUDA packages upstream
    # and causes large evaluation slowdowns. Disable for the flash script build.
    configureCuda = false;
  };
}
