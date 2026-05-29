{ config, lib, pkgs, ... }:

{
  # hardware-configuration.nix is NOT imported here — the parent flake adds
  # either ./hardware-configuration.nix (runtime, ext4 root on USB) or
  # nixos-raspberrypi.nixosModules.sd-image (one-shot installer build).
  imports = [
    ../../modules/common.nix
    ../../modules/nas.nix
  ];

  # Bootloader: nixos-raspberrypi `kernel` mode (same as gallifrey).
  boot.loader.raspberry-pi = {
    bootloader = "kernel";
    configurationLimit = 3;
  };

  networking.hostName = "vulcan";
  networking.networkmanager.enable = true;

  # Pi is on ethernet — strip ~800 MB of generic linux-firmware (Intel WiFi,
  # AMD/Nvidia GPU blobs, etc.) that nothing on vulcan can use. The Pi's
  # own GPU/VPU firmware (raspberrypi-firmware) is separate and stays.
  # mkForce because nixos-raspberrypi's base module turns this on.
  hardware.enableRedistributableFirmware = lib.mkForce false;

  # ZFS hostid migrated from the Armbian install so `zpool import` doesn't
  # see a foreign-host marker and refuse the pool. Extracted via:
  #   od -An -tx4 -N4 /etc/hostid
  networking.hostId = "636587de";

  # Auto-import the data pool (`birdpool`, 3 USB-attached drives). Root is
  # ext4, not ZFS, so no zfs-on-root concerns.
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.extraPools = [ "birdpool" ];

  services.zfs = {
    autoScrub.enable = true;
    autoScrub.interval = "monthly";
    trim.enable = true;
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.trusted-users = [ "root" "robin" ];

  environment.enableAllTerminfo = true;

  # Local accounts for SMB users. UIDs preserved so files on birdpool keep
  # their existing ownership when the pool is re-imported. No password hash
  # in git — `initialPassword` only seeds the very first login, then becomes
  # inert once the user runs `passwd`.
  # Samba auth uses a separate passdb (TDB), so after first deploy run:
  #   smbpasswd -a robin && smbpasswd -a erika && smbpasswd -a backups
  users.users.robin.uid = 1000;
  users.users.erika = {
    isNormalUser = true;
    uid = 1001;
    initialPassword = "eevee";
  };
  users.users.backups = {
    isNormalUser = true;
    uid = 1002;
    initialPassword = "eevee";
  };

  system.stateVersion = "25.11";
}
