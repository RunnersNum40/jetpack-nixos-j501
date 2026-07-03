{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.hardware.nvidia-jetpack;
  j501Cfg = config.hardware.j501;

  baseOverlayDtbs = [
    "L4TConfiguration.dtbo"
    "T234SetFmpImageTypeGuid.dtbo"
    "tegra234-carveouts.dtbo"
    "tegra-optee.dtbo"
  ];

  j501xConf = pkgs.writeText "recomputer-mini-agx-orin-j501x.conf" ''
    source "''${LDK_DIR}/p3737-0000-p3701-0000.conf";

    update_flash_args_j501x()
    {
        if [ "''${board_sku}" = "0004" ]; then
            PMIC_CONFIG="tegra234-mb1-bct-pmic-p3701-0005.dts";
            DTB_FILE=tegra234-j501x-0000+p3701-0004-recomputer-mini.dtb;
        elif [ "''${board_sku}" = "0005" ]; then
            PMIC_CONFIG="tegra234-mb1-bct-pmic-p3701-0005.dts";
            DTB_FILE=tegra234-j501x-0000+p3701-0005-recomputer-mini.dtb;
        else
            echo "Error: Unsupported board_sku ''${board_sku}";
            exit 1;
        fi
        TBCDTB_FILE="''${DTB_FILE}";
    }

    update_flash_args()
    {
        update_flash_args_common
        update_flash_args_j501x
    }

    ODMDATA="gbe-uphy-config-22,nvhs-uphy-config-0,hsio-uphy-config-0,gbe0-enable-10g,hsstp-lane-map-3";
    PINMUX_CONFIG="tegra234-mb1-bct-pinmux-p3701-0000-a04.dtsi";
    PMC_CONFIG="tegra234-mb1-bct-padvoltage-p3701-0000-a04.dtsi";
    MB2_BCT="tegra234-mb2-bct-misc-p3701-seeed-no-cvb-eeprom.dts";
    DTB_FILE=tegra234-j501x-0000+p3701-0004-recomputer-mini.dtb;
    TBCDTB_FILE="''${DTB_FILE}";
    OVERLAY_DTB_FILE="${lib.concatStringsSep "," (baseOverlayDtbs ++ j501Cfg.extraOverlayDtbFiles)}";
  '';

  # J501 Mini has no CVB EEPROM; MB2 fails if cvb_eeprom_read_size != 0.
  mb2BctNoCvb = pkgs.writeText "tegra234-mb2-bct-misc-p3701-seeed-no-cvb-eeprom.dts" ''
    /dts-v1/;
    #include "tegra234-mb2-bct-common.dtsi"
    / {
        mb2-misc {
            eeprom {
                cvb_eeprom_read_size = <0>;
            };
        };
    };
  '';

  # DTBs from Seeed MFI; not published in any public BSP repo.
  j501xDtb32gb = ../bsp/tegra234-j501x-0000+p3701-0004-recomputer-mini.dtb;
  j501xDtb64gb = ../bsp/tegra234-j501x-0000+p3701-0005-recomputer-mini.dtb;
in
{
  # Re-declaring a types.enum option extends allowed values via
  # functor.binOp = unique (a ++ b); no fork of the upstream module needed.
  options.hardware.nvidia-jetpack.carrierBoard = lib.mkOption {
    type = lib.types.enum [ "recomputer-j501-mini" ];
  };

  options.hardware.j501.extraOverlayDtbFiles = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Additional DTBO filenames appended to OVERLAY_DTB_FILE when building the J501 flash script.";
  };

  config = lib.mkIf (cfg.enable && cfg.carrierBoard == "recomputer-j501-mini") {
    assertions = [
      {
        assertion = cfg.som == "orin-agx";
        message = "recomputer-j501-mini requires hardware.nvidia-jetpack.som = \"orin-agx\"";
      }
      {
        assertion = cfg.majorVersion == "7";
        message = "recomputer-j501-mini requires hardware.nvidia-jetpack.majorVersion = \"7\" (JetPack 7 / L4T r39)";
      }
    ];

    hardware.nvidia-jetpack = {
      firmware.variants = [
        {
          boardid = "3701";
          boardsku = "0004";
          fab = "300";
          boardrev = "";
          fuselevel = "fuselevel_production";
          chiprev = "";
          chipsku = "00:00:00:D2";
        }
        {
          boardid = "3701";
          boardsku = "0005";
          fab = "300";
          boardrev = "";
          fuselevel = "fuselevel_production";
          chiprev = "";
          chipsku = "00:00:00:D0";
        }
      ];

      flashScriptOverrides = {
        targetBoard = "recomputer-mini-agx-orin-j501x";

        postPatch = ''
          cp ${j501xConf} recomputer-mini-agx-orin-j501x.conf
          cp ${mb2BctNoCvb} bootloader/generic/BCT/tegra234-mb2-bct-misc-p3701-seeed-no-cvb-eeprom.dts
          cp ${j501xDtb32gb} bootloader/tegra234-j501x-0000+p3701-0004-recomputer-mini.dtb
          cp ${j501xDtb64gb} bootloader/tegra234-j501x-0000+p3701-0005-recomputer-mini.dtb
          mkdir -p kernel/dtb
          cp ${j501xDtb32gb} kernel/dtb/tegra234-j501x-0000+p3701-0004-recomputer-mini.dtb
          cp ${j501xDtb64gb} kernel/dtb/tegra234-j501x-0000+p3701-0005-recomputer-mini.dtb
        '';
      };
    };

    # Enable the wireless stack for the M.2 Key E slot (PCIe x1 + USB).
    # Card-specific drivers (iwlwifi, rtw88, etc.) and firmware are left to users.
    boot.kernelPatches = [
      {
        name = "j501-m2-key-e-wireless-stack";
        patch = null;
        structuredExtraConfig = with lib.kernel; {
          CFG80211 = module;
          MAC80211 = module;
          RFKILL = module;
          BT = module;
          BT_HCIBTUSB = module;
        };
      }
    ];

    # Upstream enables nvfancontrol only for devkit carrier boards.
    services.nvfancontrol.enable = lib.mkDefault true;
  };
}
