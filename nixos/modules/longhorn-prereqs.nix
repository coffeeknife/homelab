{ config, ... }:

{
  # open-iscsi: required for Longhorn to attach block volumes to nodes
  services.openiscsi = {
    enable = true;
    name = "iqn.2025-01.dev.wrenspace:node.${config.networking.hostName}";
  };

  # Longhorn probes iscsiadm and mount via nsenter into the host namespace.
  # On NixOS binaries live in the Nix store; create compat symlinks at standard FHS paths.
  system.activationScripts.longhorn-iscsi-compat = ''
    mkdir -p /usr/bin /usr/sbin /usr/local/sbin /sbin /bin
    ln -sf /run/current-system/sw/bin/iscsiadm /usr/bin/iscsiadm
    ln -sf /run/current-system/sw/bin/iscsiadm /usr/sbin/iscsiadm
    ln -sf /run/current-system/sw/sbin/multipathd /usr/sbin/multipathd
    ln -sf /run/current-system/sw/bin/mount /usr/bin/mount
    ln -sf /run/current-system/sw/bin/mount /bin/mount
    ln -sf /run/current-system/sw/bin/umount /usr/bin/umount
    ln -sf /run/current-system/sw/bin/umount /bin/umount
  '';

  # NFS client: needed for vulcan NFS volumes (documents, photos, media)
  boot.supportedFilesystems = [ "nfs" ];
  services.rpcbind.enable = true;

  # Ensure k3s only starts after iSCSI and multipath daemons are ready
  systemd.services.k3s = {
    requires = [ "iscsid.service" ];
    after    = [ "iscsid.service" ];
  };
}
