{ config, lib, pkgs, ... }:

{
  # hardware-configuration.nix is NOT imported here — the parent flake adds
  # either ./hardware-configuration.nix (runtime) or
  # nixos-raspberrypi.nixosModules.sd-image (one-shot installer build).
  imports = [
    ../../modules/common.nix
  ];

  # Bootloader: nixos-raspberrypi's `uboot` mode — the GPU firmware loads
  # U-Boot, which boots via generic-extlinux-compatible from ext4 /boot.
  # Kernel + initrd live on the ext4 root, NOT the small (30MB) FAT FIRMWARE
  # partition (which only holds firmware + u-boot + config.txt). The previous
  # `kernel` mode wrote a ~32MB kernel into the undersized FAT and corrupted
  # config.txt on every generation switch — see git history (2026-07-08).
  # nixos-raspberrypi owns hardware overlays and device-tree selection, so
  # no `hardware.raspberry-pi` / `hardware.deviceTree` config is needed here.
  boot.loader.raspberry-pi = {
    bootloader = "uboot";
    configurationLimit = 3;
  };

  # Pi is on ethernet — strip ~400 MB of x86 GPU / Intel WiFi blobs that
  # nothing on a Pi can use. mkForce because nixos-raspberrypi's base
  # module turns this on.
  hardware.enableRedistributableFirmware = lib.mkForce false;

  networking.hostName = "gallifrey";
  networking.networkmanager.enable = true;

  # Append host-specific groups for Docker compose stacks and USB radio
  # access; common.nix already declares the user with the wheel group.
  users.users.robin = {
    extraGroups = [ "docker" "usb" ];
    packages    = with pkgs; [ tree ];
  };

  # Docker runs the host's compose stacks (zigbee, thread, diun, act-runner).
  # (This node no longer runs k3s — removed 2026-07-08.)
  virtualisation.docker = {
    enable = true;
    # Weekly Docker prune so the SD card doesn't fill up with stopped
    # containers, dangling images, and orphan volumes from the compose
    # stacks. Only keeps content used in the last 168h.
    autoPrune = {
      enable = true;
      dates  = "Sun *-*-* 03:00:00";
      flags  = [ "--all" "--volumes" "--filter" "until=168h" ];
    };
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.trusted-users = [ "root" "robin" ];

  environment.enableAllTerminfo = true;

  system.stateVersion = "25.11";
}
