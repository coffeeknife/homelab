{ config, ... }:

{
  # open-iscsi: required for Longhorn to attach block volumes to nodes
  services.openiscsi = {
    enable = true;
    name = "iqn.2025-01.dev.wrenspace:node.${config.networking.hostName}";
  };

  # Longhorn probes iscsiadm at /usr/bin/iscsiadm via nsenter into the host namespace.
  # On NixOS the binary lives in the Nix store; create a compat symlink.
  system.activationScripts.longhorn-iscsi-compat = ''
    mkdir -p /usr/bin /usr/sbin /usr/local/sbin
    ln -sf /run/current-system/sw/bin/iscsiadm /usr/bin/iscsiadm
    ln -sf /run/current-system/sw/bin/iscsiadm /usr/sbin/iscsiadm
    ln -sf /run/current-system/sw/sbin/multipathd /usr/sbin/multipathd
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
