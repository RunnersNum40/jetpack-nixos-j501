{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.hardware.j501.gmsl;
  dtboName = "tegra234-camera-seeed-gmsl-2x1x4-isx031.dtbo";
  dtbo = pkgs.callPackage ../bsp/gmsl/dtbo.nix { inherit (cfg) fsyncHz; };
in
{
  options.hardware.j501.gmsl = {
    enable = lib.mkEnableOption "Seeed GMSL2 camera expansion board";

    installTools = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install v4l-utils for camera diagnostics.";
    };

    fsyncHz = lib.mkOption {
      type = lib.types.ints.between 0 120;
      default = 0;
      example = 60;
      description = ''
        Frame-sync rate in Hz, or 0 to leave the cameras free-running.
        Each deserializer runs its internal FSYNC generator at this rate
        (25 MHz crystal timebase) and every connected sensor is slaved to
        it over the GMSL back-channel, frame-locking the cameras that
        share a deserializer to within microseconds. 1 Hz overflows the
        hardware period register and is rejected.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.fsyncHz != 1;
        message = "hardware.j501.gmsl.fsyncHz: 1 Hz overflows the 24-bit FSYNC period register; use 0 (off) or 2-120.";
      }
    ];

    hardware.j501.extraOverlayDtbFiles = [ dtboName ];

    hardware.nvidia-jetpack.flashScriptOverrides.postPatch = lib.mkAfter ''
      cp ${dtbo}/${dtboName} bootloader/${dtboName}
      cp ${dtbo}/${dtboName} kernel/dtb/${dtboName}
    '';

    environment.systemPackages = lib.mkIf cfg.installTools [ pkgs.v4l-utils ];

    # Seeed's GMSL stack (Linux_for_Tegra r36.4.3): max_serdes framework,
    # max96724/max96717 drivers, and nv_cam, a generic DT-table-driven
    # tegracam sensor subdev — none exist in stock nvidia-oot.
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

                    # nv_cam needs tegracam/camera_common, so it and the
                    # serdes subdir must join the sensor-driver Makefile
                    # block; anchor on nv_hawk_owl.
                    substituteInPlace nvidia-oot/drivers/media/i2c/Makefile \
                      --replace-fail 'obj-m += nv_hawk_owl.o' 'obj-m += nv_hawk_owl.o
                    obj-m += nv_cam.o
                    obj-m += maxim-serdes/'

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
    ];

    # Ser/des subdev pad formats reset to FIXED/0x0 every boot; capture
    # fails until every probed channel entity is set (Seeed's flow).
    systemd.services.gmsl-subdev-formats = {
      description = "Set GMSL ser/des subdev formats";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Discovery + waiting for staggered camera probes to settle can run
        # well past systemd's 90s default.
        TimeoutStartSec = 180;
      };
      script = ''
        # The expansion board is optional. If no deserializer media device
        # appears, there is nothing to configure.
        mediadev=
        for _ in $(seq 1 60); do
          for m in /dev/media*; do
            [ -e "$m" ] || continue
            if ${pkgs.v4l-utils}/bin/media-ctl -d "$m" -p 2>/dev/null \
                 | grep -qE 'entity [0-9]+: des_[0-9]+_ch_'; then
              mediadev="$m"
              break
            fi
          done
          [ -n "$mediadev" ] && break
          sleep 0.5
        done
        if [ -z "$mediadev" ]; then
          echo "no GMSL media device; nothing to configure" >&2
          exit 0
        fi

        # nv_cam can defer for up to 45 seconds while links train. Wait through
        # that bound before deciding which serializer channels are populated.
        sleep 45

        list_entities() {
          ${pkgs.v4l-utils}/bin/media-ctl -d "$mediadev" -p \
            | sed -n 's/^- entity [0-9]*: \(\(ser\|des\)_[0-9]*_ch_[0-9]*\) .*/\1/p' \
            | sort
        }
        prev=; stable=0; entities=
        for _ in $(seq 1 120); do
          cur=$(list_entities)
          if [ -n "$cur" ] && [ "$cur" = "$prev" ]; then
            stable=$((stable + 1))
            [ "$stable" -ge 6 ] && { entities="$cur"; break; }
          else
            stable=0
          fi
          prev="$cur"
          sleep 0.5
        done
        [ -n "$entities" ] || entities="$prev"

        serializer_count=$(printf '%s\n' "$entities" | grep -c '^ser_' || true)
        if [ "$serializer_count" -eq 0 ]; then
          echo "no attached GMSL cameras; nothing to configure" >&2
          exit 0
        fi

        fmt="YUYV8_1X16/1920x1536"

        # media-ctl enumerates every channel of both deserializers, but
        # only the connectors with a camera attached have a populated
        # pipeline. A channel whose subdev/pad is absent (empty connector)
        # fails with ENOENT and is skipped; a channel that exists but
        # rejects the format is a real error and must not be masked by
        # another channel succeeding. Require at least one real channel.
        set_count=0
        configured_serializers=0
        for e in $entities; do
          case "$e" in
            ser_*) pad=1 ;;
            des_*) pad=0 ;;
          esac
          if err=$(${pkgs.v4l-utils}/bin/media-ctl -d "$mediadev" \
               --set-v4l2 "\"$e\":$pad[fmt:$fmt]" 2>&1); then
            set_count=$((set_count + 1))
            case "$e" in ser_*) configured_serializers=$((configured_serializers + 1)) ;; esac
          elif [ "''${err#*No such file or directory}" != "$err" ]; then
            : # channel not populated (empty connector) -- skip
          else
            echo "media-ctl rejected $fmt on $e: $err" >&2
            exit 1
          fi
        done
        [ "$set_count" -gt 0 ] || { echo "no GMSL channel accepted $fmt" >&2; exit 1; }
        [ "$configured_serializers" -eq "$serializer_count" ] || {
          echo "configured $configured_serializers of $serializer_count GMSL cameras" >&2
          exit 1
        }
      '';
    };
  };
}
