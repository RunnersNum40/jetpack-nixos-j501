{
  config,
  lib,
  ...
}:

let
  cfg = config.hardware.j501.rs485;
  dtboName = "j501-rs485-enable.dtbo";
in
{
  options.hardware.j501.rs485.enable = lib.mkEnableOption ''
    the J501 Mini onboard RS485 port (/dev/ttyTHS4). Applies a device-tree
    overlay whose GPIO hogs hold the transceiver-enable (main gpio line 126)
    and 120R termination (aon gpio line 9) low from kernel probe, so the bus
    is live with no userspace daemon
  '';

  # dtboSrc inside mkIf so the path is only evaluated when enabled.
  config = lib.mkIf cfg.enable (
    let
      dtboSrc = ../bsp/rs485/${dtboName};
    in
    {
      hardware.j501.extraOverlayDtbFiles = [ dtboName ];

      hardware.nvidia-jetpack.flashScriptOverrides.postPatch = lib.mkAfter ''
        cp ${dtboSrc} bootloader/${dtboName}
        cp ${dtboSrc} kernel/dtb/${dtboName}
      '';
    }
  );
}
