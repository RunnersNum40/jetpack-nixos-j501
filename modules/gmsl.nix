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

    installTools = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install v4l-utils for camera diagnostics.";
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

      environment.systemPackages = lib.mkIf cfg.installTools [ pkgs.v4l-utils ];

      # MAX96717 serializer driver is a hard blocker; see bsp/gmsl/README.md for current status.
    }
  );
}
