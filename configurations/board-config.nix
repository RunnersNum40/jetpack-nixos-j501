{ lib, pkgs, ... }:
{
  nixpkgs.config.allowUnfree = true;
  hardware.graphics.enable = true;
  system.stateVersion = "26.05";

  networking = {
    hostName = "j501";
    useDHCP = lib.mkDefault true;
  };

  disko.devices.disk.nvme = {
    type = "disk";
    device = "/dev/nvme0n1";
    content = {
      type = "gpt";
      partitions = {
        esp = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };

  boot = {
    loader.systemd-boot.enable = true;
    # Jetson L4T UEFI stores boot entries in QSPI, not writable from Linux.
    loader.efi.canTouchEfiVariables = false;
  };

  services.openssh = {
    enable = true;
  };
}
