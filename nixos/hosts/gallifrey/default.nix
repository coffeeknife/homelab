{ config, lib, pkgs, ... }:

{
  # hardware-configuration.nix is NOT imported here — the parent flake adds
  # either ./hardware-configuration.nix (runtime) or
  # nixos-raspberrypi.nixosModules.sd-image (one-shot installer build).
  imports = [
    ../../modules/common.nix
  ];

  # Bootloader: stock generic-extlinux-compatible.
  #
  # nixos-raspberrypi's own bootloader builders (`kernel`/`uboot`) re-copy the
  # ~22MB RPi vendor firmware (start*.elf) into the 30MB FAT FIRMWARE partition
  # on EVERY activation. That overflows it (copy-to-.tmp roughly doubles peak
  # usage), which is what corrupted boot under the old `kernel` mode. But the
  # FAT firmware + u-boot-rpi4.bin + config.txt are already installed and are
  # static — they don't change per generation. So we disable nixos-raspberrypi's
  # bootloader management entirely and let stock extlinux write ONLY to the ext4
  # /boot (kernels + extlinux.conf, ample space). U-Boot on the FAT chain-loads
  # that extlinux config. This is the historically-working pre-May-2026 setup.
  # (configurationLimit for extlinux is set to 3 in modules/common.nix.)
  boot.loader.raspberry-pi.enable = lib.mkForce false;
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.generic-extlinux-compatible.enable = true;

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

  # Docker runs the host's compose stacks (zigbee, thread, diun).
  # (This node no longer runs k3s — removed 2026-07-08. The act-runner stack
  # moved into the k3s cluster as apps/infrastructure/gitea-actions — 2026-07-23.)
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
