# Hardware configuration for vulcan (Raspberry Pi 4, USB-attached boot drive).
# Filesystems bound by label to survive USB-port reshuffles. Labels match the
# defaults of the nixos-raspberrypi installer image:
#   FIRMWARE  -> FAT32 boot partition
#   NIXOS_SD  -> ext4 root (rename to NIXOS-ROOT after install if you prefer)
#
# After the first nixos-install on the new USB drive, run `nixos-generate-config`
# and reconcile any deltas here.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # Modules needed in initrd to bring up USB storage (rootfs is on USB).
  # `uas` is the modern USB-attached-SCSI driver; many USB-SATA bridges need it.
  boot.initrd.availableKernelModules = [ "xhci_pci" "usb_storage" "uas" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
  };

  # FAT firmware partition managed by the nixos-raspberrypi `kernel` bootloader.
  # Lazy-mounted via systemd so it only spins up on writes (generation switch).
  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = [ "noatime" "noauto" "x-systemd.automount" "x-systemd.idle-timeout=1min" ];
  };

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
