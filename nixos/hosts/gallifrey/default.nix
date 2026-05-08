{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/common.nix
    ../../modules/k3s-agent.nix
  ];

  # extlinux instead of GRUB for Pi boot
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  # nixos-hardware forces linuxPackages_rpi4 (not cached); override to the
  # standard aarch64 kernel which is fully substitutable from cache.nixos.org.
  boot.kernelPackages = pkgs.linuxPackages;

  networking.hostName = "gallifrey";
  networking.networkmanager.enable = true;

  # Append host-specific groups for Docker compose stacks and USB radio
  # access; common.nix already declares the user with the wheel group.
  users.users.robin = {
    extraGroups = [ "docker" "usb" ];
    packages    = with pkgs; [ tree ];
  };

  # Keep Docker for the existing compose stacks (zigbee, thread, diun,
  # act-runner) while k3s also runs containerd. Both share kernel resources
  # but use separate runtimes and sockets.
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
