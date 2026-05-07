{ pkgs, ... }:

{
  # Boot
  boot.kernelParams = [
    "cgroup_no_v1=all"
    "systemd.unified_cgroup_hierarchy=1"
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

  time.timeZone = "America/Chicago";
}
