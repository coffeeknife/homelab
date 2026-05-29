# Shared NAS module: NFS server + Samba shares.
# Currently only vulcan imports this, but it's a module so a future
# NAS replica could reuse it.
{ config, lib, pkgs, ... }:

{
  # ---- NFS ----------------------------------------------------------------
  # nfsd is enabled but the export table itself is owned by ZFS, not nix.
  # Each dataset on `birdpool` carries its own `sharenfs` property and ZFS's
  # `zfs-share.service` registers those with the kernel NFS server at boot.
  # The Armbian setup worked this way; migrating the property along with the
  # pool (no `zpool upgrade`, no property changes) means exports just come
  # back when the pool imports.
  services.nfs.server = {
    enable = true;
    # Pin lock ports so they're stable if firewall.enable ever flips on.
    lockdPort  = 4001;
    mountdPort = 4002;
    statdPort  = 4003;
    # Do NOT set `exports` here — keep /etc/exports empty so the ZFS-managed
    # exports in /etc/exports.d/zfs.exports are the single source of truth.
  };

  # rpc-statd / rpcbind sometimes race with zfs-mount/zfs-share on boot.
  # Make sure nfsd waits until the pool's datasets are mounted AND zfs
  # has had a chance to push its sharenfs entries to the kernel.
  systemd.services.nfs-server = {
    after    = [ "zfs-mount.service" "zfs-share.service" "zfs.target" ];
    requires = [ "zfs-mount.service" ];
  };

  # ---- Samba --------------------------------------------------------------
  # Shares lifted from the Armbian box's Samba registry (`net conf list`),
  # which cockpit-file-sharing had been writing to /var/lib/samba/registry.tdb.
  # Re-expressed as plain smb.conf sections so the source of truth lives in
  # git, not a TDB.
  services.samba = {
    enable = true;
    openFirewall = true;
    # NixOS 25.05+ uses the structured `settings` attrset. Each top-level
    # attr is a Samba section ([global], [sharename], ...).
    settings = {
      global = {
        "workgroup"               = "WORKGROUP";
        "server string"           = "Local file sharing";
        "netbios name"            = "vulcan";
        "security"                = "user";
        "map to guest"            = "bad user";
        "guest account"           = "nobody";
        # PAM hooks carried over from the Debian default smb.conf so
        # `smbpasswd` and the Unix password stay synced.
        "obey pam restrictions"   = "yes";
        "unix password sync"      = "yes";
        "pam password change"     = "yes";
        # macOS Finder friendliness:
        "vfs objects"             = "catia fruit streams_xattr";
        "fruit:metadata"          = "stream";
        "fruit:model"             = "MacSamba";
        "fruit:posix_rename"      = "yes";
        "fruit:veto_appledouble"  = "no";
        "fruit:delete_empty_adfiles" = "yes";
      };

      "TV" = {
        path = "/mnt/birdpool/jellyfin/media/tv";
        comment = "TV shows";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "inherit permissions" = "no";
      };
      "Movies" = {
        path = "/mnt/birdpool/jellyfin/media/movies";
        comment = "jellyfin movies";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "inherit permissions" = "no";
      };
      "Books" = {
        path = "/mnt/birdpool/kavita/data";
        comment = "books n manga";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "inherit permissions" = "no";
      };
      "Backups" = {
        path = "/mnt/birdpool/backups";
        comment = "Backups";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "inherit permissions" = "no";
      };
    };
  };

  # WS-Discovery so Windows hosts see vulcan under Network without manual
  # \\hostname lookups. Samba dropped its own browsing announce when SMB1
  # was removed.
  services.samba-wsdd = {
    enable = true;
    openFirewall = true;
  };
}
