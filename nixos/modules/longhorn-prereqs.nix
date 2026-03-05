{ config, ... }:

{
  # open-iscsi: required for Longhorn to attach block volumes to nodes
  services.openiscsi = {
    enable = true;
    name = "iqn.2025-01.dev.wrenspace:node.${config.networking.hostName}";
  };

  # NFS client: needed for vulcan NFS volumes (documents, photos, media)
  boot.supportedFilesystems = [ "nfs" ];
  services.rpcbind.enable = true;

  # Ensure k3s only starts after iSCSI and multipath daemons are ready
  systemd.services.k3s = {
    requires = [ "iscsid.service" ];
    after    = [ "iscsid.service" ];
  };
}
