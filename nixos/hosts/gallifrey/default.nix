{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/common.nix
    ../../modules/k3s-agent.nix
  ];

  hardware = {
    raspberry-pi."4".apply-overlays-dtmerge.enable = true;
    deviceTree = {
      enable = true;
      filter = "*rpi-4-*.dtb";
    };
  };

  # extlinux instead of GRUB for Pi boot
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

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
  virtualisation.docker.enable = true;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Weekly Docker maintenance — prunes images, containers, networks,
  # and dangling volumes not used by the running compose stacks. The
  # Pi's SD card fills up fast otherwise.
  systemd.services.docker-prune = {
    description = "Prune unused Docker images, containers, networks, volumes";
    serviceConfig = {
      Type      = "oneshot";
      ExecStart = "${pkgs.docker}/bin/docker system prune -af --volumes --filter until=168h";
    };
  };
  systemd.timers.docker-prune = {
    description = "Run docker-prune weekly";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 03:00:00";
      Persistent = true;
    };
  };

  environment.enableAllTerminfo = true;

  system.stateVersion = "25.11";
}
