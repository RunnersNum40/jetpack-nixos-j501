{ ... }:
{
  hardware.nvidia-jetpack = {
    enable = true;
    som = "orin-agx";
    carrierBoard = "recomputer-j501-mini";
    majorVersion = "7";
    configureCuda = false;
  };
}
