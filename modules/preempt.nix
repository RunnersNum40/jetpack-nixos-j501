{ config, lib, ... }:
{
  options.hardware.j501.fullPreempt.enable = lib.mkEnableOption ''
    full kernel preemption (CONFIG_PREEMPT=y).
  '';

  config = lib.mkIf config.hardware.j501.fullPreempt.enable {
    boot.kernelPatches = [
      {
        name = "full-preempt";
        patch = null;
        structuredExtraConfig = {
          # mkForce both: nixpkgs' common-config pins PREEMPT=n / VOLUNTARY=y.
          PREEMPT = lib.mkForce lib.kernel.yes;
          PREEMPT_VOLUNTARY = lib.mkForce lib.kernel.no;
        };
      }
    ];
  };
}
