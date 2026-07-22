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
    "2x1x4-isx031" = "tegra234-camera-seeed-gmsl-2x1x4-isx031.dtbo";
  };

  dtboName = variantDtboFile.${cfg.variant};

  # Media-bus format per serdes-stack variant, applied to every ser/des
  # channel subdev each boot. The 1x4 variants predate the vendored stack
  # (bsp/gmsl/oot) and still bind the stock max96712 stub; see
  # bsp/gmsl/README.md.
  variantSubdevFormat = {
    "2x1x4-isx031" = "YUYV8_1X16/1920x1536";
  };
  useSerdesStack = variantSubdevFormat ? ${cfg.variant};
in
{
  options.hardware.j501.gmsl = {
    enable = lib.mkEnableOption "Seeed GMSL2 camera expansion board";

    variant = lib.mkOption {
      type = lib.types.enum (lib.attrNames variantDtboFile);
      # Default to the only variant on the working vendored stack; the 1x4
      # variants still bind the stock max96712 stub (see bsp/gmsl/README.md).
      default = "2x1x4-isx031";
      description = ''
        GMSL overlay variant matching the connected camera model:
        - "2x1x4-isx031": ISX031 + MAX9295A modules (e.g. Arducam 3MP ISX031
          GMSL2, 6 Gbps link), up to 8 cameras across both mini-FAKRA
          connectors. Vendored Seeed maxim-serdes + nv_cam drivers.
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

  # dtboSrc stays inside mkIf so the path is only evaluated when enabled.
  config = lib.mkIf cfg.enable (
    let
      dtboSrc = ../bsp/gmsl/${dtboName};
    in
    lib.mkMerge [
      {
        hardware.j501.extraOverlayDtbFiles = [ dtboName ];

        hardware.nvidia-jetpack.flashScriptOverrides.postPatch = lib.mkAfter ''
          cp ${dtboSrc} bootloader/${dtboName}
          cp ${dtboSrc} kernel/dtb/${dtboName}
        '';

        environment.systemPackages = lib.mkIf cfg.installTools [ pkgs.v4l-utils ];
      }

      (lib.mkIf useSerdesStack {
        # Seeed's GMSL stack (Linux_for_Tegra r36.4.3): max_serdes framework,
        # max96724/max96717 drivers, and nv_cam, a generic DT-table-driven
        # tegracam sensor subdev — none exist in stock nvidia-oot. obc_cam_sync
        # is nv_cam's frame-sync link dependency (dormant when free-running).
        nixpkgs.overlays = [
          (final: prev: {
            nvidia-jetpack = prev.nvidia-jetpack.overrideScope (
              _: jprev: {
                kernelPackagesOverlay = final.lib.composeExtensions jprev.kernelPackagesOverlay (
                  _: kprev: {
                    nvidia-oot-modules = kprev.nvidia-oot-modules.overrideAttrs (old: {
                      postPatch = (old.postPatch or "") + ''
                        cp -r --no-preserve=all ${../bsp/gmsl/oot/maxim-serdes} \
                          nvidia-oot/drivers/media/i2c/maxim-serdes
                        cp ${../bsp/gmsl/oot/nv_cam.c} nvidia-oot/drivers/media/i2c/nv_cam.c
                        cp ${../bsp/gmsl/oot/obc_cam_sync.c} nvidia-oot/drivers/misc/obc_cam_sync.c
                        cp ${../bsp/gmsl/oot/obc_cam_sync.h} nvidia-oot/drivers/misc/obc_cam_sync.h

                        # nv_cam needs tegracam/camera_common, so it and the
                        # serdes subdir must join the sensor-driver Makefile
                        # block; anchor on nv_hawk_owl.
                        substituteInPlace nvidia-oot/drivers/media/i2c/Makefile \
                          --replace-fail 'obj-m += nv_hawk_owl.o' 'obj-m += nv_hawk_owl.o
                        obj-m += nv_cam.o
                        obj-m += maxim-serdes/'

                        echo 'obj-m += obc_cam_sync.o' >> nvidia-oot/drivers/misc/Makefile

                        # Sensors behind an i2c-atr virtual bus have no Tegra
                        # i2c controller MMIO parent; stock sensor_common hard-
                        # fails probe on the missing regbase (only the unused
                        # RTCPU direct-i2c path needs it). Same fix Seeed ships.
                        patch -p1 < ${../bsp/gmsl/oot/sensor_common-atr-bus.patch}

                        # nv_cam is DT-driven and ships no static frmfmt_table;
                        # stock r39 tegracam_device_register dereferences that
                        # NULL table. Restore Seeed's fallback that builds frmfmt
                        # from the DT sensor modes (camera_common_fill_fmts).
                        patch -p1 < ${../bsp/gmsl/oot/tegracam-dt-frmfmt.patch}

                        # The VI channel's upstream walk assumes each subdev's
                        # sink pad sits at (source_pad - 1); serdes channel
                        # subdevs order source first, truncating the chain
                        # before the sensor (vi-output bound to des_N_ch_N).
                        patch -p1 < ${../bsp/gmsl/oot/vi-channel-subdev-walk.patch}

                        # The CSI channel's s_data is linked in a separate walk
                        # (tegra_channel_connect_sensor) that matches the sensor's
                        # OF endpoint against nvcsi nodes; for serdes the sensor
                        # endpoint targets the serializer, so it stays NULL and
                        # NVCSI's mipi_clock_rate falls back to csi->clk_freq
                        # (~102 MHz) -> RCE mistunes T_HS_SETTLE -> SOT storm, no
                        # frames. Recover the real MIPI clock from the VI channel.
                        patch -p1 < ${../bsp/gmsl/oot/csi-mipi-clock-serdes.patch}
                      '';
                    });
                  }
                );
              }
            );
          })
        ];

        # All autoload via OF modaliases / symbol deps; listed for determinism.
        # i2c-atr is pulled in as a symbol dependency of max_serdes_all.
        boot.kernelModules = [
          "max_serdes_all"
          "max96724"
          "max96717"
          "nv_cam"
          "obc_cam_sync"
        ];

        # Ser/des subdev pad formats reset to FIXED/0x0 every boot; capture
        # fails until every probed channel entity is set (Seeed's flow).
        systemd.services.gmsl-subdev-formats = {
          description = "Set GMSL ser/des subdev formats";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            # nv_cam probe is deferred until the deserializer finishes link
            # training, so the media/video nodes appear seconds after boot and
            # their numbers are not stable across probe order. Find the media
            # device whose graph actually holds GMSL ser/des channel entities.
            mediadev=
            for _ in $(seq 1 60); do
              for m in /dev/media*; do
                [ -e "$m" ] || continue
                if ${pkgs.v4l-utils}/bin/media-ctl -d "$m" -p 2>/dev/null \
                     | grep -qE 'entity [0-9]+: (ser|des)_[0-9]+_ch_'; then
                  mediadev="$m"
                  break
                fi
              done
              [ -n "$mediadev" ] && ls /dev/video* >/dev/null 2>&1 && break
              sleep 0.5
            done
            [ -n "$mediadev" ] || { echo "no GMSL media device" >&2; exit 1; }

            fmt="${variantSubdevFormat.${cfg.variant}}"
            entities=$(${pkgs.v4l-utils}/bin/media-ctl -d "$mediadev" -p \
              | sed -n 's/^- entity [0-9]*: \(\(ser\|des\)_[0-9]*_ch_[0-9]*\) .*/\1/p')
            [ -n "$entities" ] || { echo "no GMSL channel entities" >&2; exit 1; }

            # media-ctl enumerates every channel of both deserializers, but
            # only the connectors with a camera attached have a populated
            # pipeline. A channel whose subdev/pad is absent (empty connector)
            # fails with ENOENT and is skipped; a channel that exists but
            # rejects the format is a real error and must not be masked by
            # another channel succeeding. Require at least one real channel.
            set_count=0
            for e in $entities; do
              case "$e" in
                ser_*) pad=1 ;;
                des_*) pad=0 ;;
              esac
              if err=$(${pkgs.v4l-utils}/bin/media-ctl -d "$mediadev" \
                   --set-v4l2 "\"$e\":$pad[fmt:$fmt]" 2>&1); then
                set_count=$((set_count + 1))
              elif [ "''${err#*No such file or directory}" != "$err" ]; then
                : # channel not populated (empty connector) -- skip
              else
                echo "media-ctl rejected $fmt on $e: $err" >&2
                exit 1
              fi
            done
            [ "$set_count" -gt 0 ] || { echo "no GMSL channel accepted $fmt" >&2; exit 1; }
          '';
        };
      })
    ]
  );
}
