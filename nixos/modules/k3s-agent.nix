{ config, ... }:

{
  # k3s agent — joins the k3s server at 192.168.200.2.
  # Reuses the same shared token secret as the server.

  sops.secrets.k3s-token = {
    sopsFile = ../secrets/secrets.yaml;
    key      = "k3s_token";
    path     = "/run/secrets/k3s-token";
    owner    = "root";
    mode     = "0400";
  };

  # Same flannel subnet.env quirk as the server — see comment in k3s-server.nix.
  systemd.tmpfiles.rules = [
    "d /run/flannel 0755 root root -"
  ];

  services.k3s = {
    enable     = true;
    role       = "agent";
    serverAddr = "https://192.168.200.2:6443";
    tokenFile  = config.sops.secrets.k3s-token.path;

    extraFlags = [
      # Match the server's pull-throttling so cold boots don't hammer the
      # registry and CPU.
      "--kubelet-arg=registry-qps=2"
      "--kubelet-arg=registry-burst=4"
    ];
  };

  # NFS client support required to mount vulcan-nfs PVCs.
  boot.supportedFilesystems = [ "nfs" ];
  services.rpcbind.enable = true;

  # The k3s API server is on a different /24 than this node lives on
  # (cluster net 192.168.200.0/24 vs home net 192.168.1.0/24). The home
  # router routes between them; nothing else is needed for flannel's
  # VXLAN to reach kube-vm.
}
