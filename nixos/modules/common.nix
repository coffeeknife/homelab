{ pkgs, ... }:

{
  # Boot
  boot.kernelParams = [
    "cgroup_no_v1=all"
    "systemd.unified_cgroup_hierarchy=1"
    # Headless boxes: let initrd fsck auto-repair ext4 errors that "-a" mode
    # would otherwise punt on (orphan inodes, checksum mismatches after a
    # power cut). Without this, a dirty filesystem can drop boot into an
    # emergency shell that needs physical access to clear.
    "fsck.repair=yes"
  ];

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
    # Required for Longhorn/iSCSI
    "fs.inotify.max_user_instances" = 8192;
    "fs.inotify.max_user_watches" = 524288;
  };

  # Disable NixOS firewall — k3s manages its own iptables rules and the two conflict
  networking.firewall.enable = false;
  # systemd-resolved conflicts with CoreDNS
  services.resolved.enable = false;
  networking.nameservers = [ "192.168.1.1" "8.8.8.8" ];

  # Stable name for the NAS / NFS backend so PVs and inline NFS volumes never
  # hardcode its IP. NFS is mounted by the kubelet at the *host* level (outside
  # cluster DNS/CoreDNS), so the name must resolve via the host resolver — an
  # /etc/hosts entry does that on every node. Moving the backend later is a
  # one-line change here + `colmena apply`: every PV keeps `server: nas.internal`
  # (the spec string is immutable, but the resolved IP is free to change).
  networking.hosts = {
    "192.168.1.117" = [ "nas.internal" ];
  };

  # SSH
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIe2PZOs/3wRmVtkvYpuihuk+ywyoD+l82LbCKrqvX4p Robin"
  ];

  users.users.robin = {
    isNormalUser = true;
    extraGroups  = [ "wheel" ];
    initialPassword = "Eevee";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIe2PZOs/3wRmVtkvYpuihuk+ywyoD+l82LbCKrqvX4p Robin"
    ];
  };

  # Trusted homelab boxes — wheel users sudo without a password so
  # colmena (and other automated deploys) don't need an interactive
  # askpass setup. Robin is the only wheel member.
  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = with pkgs; [
    curl
    wget
    htop
    jq
    git
    vim
    tcpdump
    ethtool
    inetutils
  ];

  sops.age.keyFile = "/root/.config/sops/age/keys.txt";

  # Aggressive Nix store maintenance — homelab boxes don't have huge
  # disks and unattended Nix accumulation has bitten us before.
  # nix-collect-garbage in nix 2.31 dropped the older --delete-generations
  # +N syntax, so we bound by age instead. 30d still preserves rollback for
  # weeks while keeping the SD card from filling. boot.loader.*.configurationLimit
  # below caps the boot menu separately, so the visible safety net is unchanged.
  nix.settings.auto-optimise-store = true;
  nix.gc = {
    automatic = true;
    dates     = "daily";
    options   = "--delete-older-than 30d";
  };
  # Cap the boot-menu entries to match the GC retention. Setting limits
  # for all three loader types is harmless — only the active one consumes
  # the option. (kube-vm uses GRUB; gallifrey uses extlinux on the Pi.)
  boot.loader.systemd-boot.configurationLimit         = 3;
  boot.loader.grub.configurationLimit                 = 3;
  boot.loader.generic-extlinux-compatible.configurationLimit = 3;

  time.timeZone = "America/Chicago";
}
