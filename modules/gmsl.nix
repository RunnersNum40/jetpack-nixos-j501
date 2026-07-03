{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.hardware.j501.gmsl;

  variantDtboFile = {
    "1x4-3g" = "tegra234-camera-seeed-gmsl-1x4-3g.dtbo";
    "1x4-6g" = "tegra234-camera-seeed-gmsl-1x4-6g.dtbo";
  };

  dtboName = variantDtboFile.${cfg.variant};
in
{
  options.hardware.j501.gmsl = {
    enable = lib.mkEnableOption "Seeed GMSL2 camera expansion board";

    variant = lib.mkOption {
      type = lib.types.enum (lib.attrNames variantDtboFile);
      default = "1x4-3g";
      description = ''
        GMSL overlay variant matching the connected camera model:
        - "1x4-3g": SG3S-ISX031C-GMSL2F (3 Gbps link rate)
        - "1x4-6g": SG2-AR0233C, SG2-IMX390C, SG8S-AR0820C (6 Gbps link rate)
      '';
    };
  };

  # dtboSrc inside mkIf: path only evaluated when GMSL is enabled, so missing
  # files don't cause errors for users without the extension board.
  config = lib.mkIf cfg.enable (
    let
      dtboSrc = ../bsp/gmsl/${dtboName};
    in
    {
      hardware.j501.extraOverlayDtbFiles = [ dtboName ];

      hardware.nvidia-jetpack.flashScriptOverrides.postPatch = lib.mkAfter ''
        cp ${dtboSrc} bootloader/${dtboName}
        cp ${dtboSrc} kernel/dtb/${dtboName}
      '';

      environment.systemPackages = [ pkgs.v4l-utils ];

      # Kernel driver status for L4T r39 (jetpack-nixos nvidia-oot rev 487ee5c0):
      #
      # MAX96712 deserializer: driver present in nvidia-oot (drivers/media/i2c/max96712.c),
      #   built as part of l4t-oot-modules. Binds to compatible = "nvidia,max96712" which
      #   matches the DTBOs here.
      #
      # MAX96717 serializer: no driver in nvidia-oot, mainline kernel-noble (6.8), or
      #   any public Seeed BSP source. This is the hard blocker — cameras cannot function
      #   without it. Seeed has not published r39 BSP sources with a MAX96717 driver.
      #
      # Once a MAX96717 driver is available (from Seeed or ported from max9295.c):
      #   1. Package the MAX96717 driver as an extraModulePackage
      #   2. Add: boot.kernelModules = [ "max96712" "max96717" ];
    }
  );
}
