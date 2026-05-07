{ config, ... }:

{
  # Custom resolv.conf for k3s so CoreDNS uses the home router as upstream.
  # This lets wrenspace.dev subdomains resolve to internal MetalLB IPs,
  # bypassing Cloudflare for in-cluster OIDC/service discovery.
  environment.etc."k3s-resolv.conf".text = "nameserver 192.168.1.1\n";

  sops.secrets.k3s-token = {
    sopsFile = ../secrets/secrets.yaml;
    key      = "k3s_token";
    path     = "/run/secrets/k3s-token";
    owner    = "root";
    mode     = "0400";
  };

  # Ensure /run/flannel exists at boot so k3s can write subnet.env.
  # Without this, k3s silently fails to initialise flannel and no pod
  # sandboxes can be created after a reboot.
  systemd.tmpfiles.rules = [
    "d /run/flannel 0755 root root -"
  ];

  services.k3s = {
    enable    = true;
    role      = "server";
    tokenFile = config.sops.secrets.k3s-token.path;

    extraFlags = [
      # Disable components managed by Flux instead
      "--disable=traefik"
      "--disable=servicelb"
      # Relax etcd timeouts for Proxmox VM disks which can have variable fsync latency
      "--etcd-arg=heartbeat-interval=500"
      "--etcd-arg=election-timeout=5000"
      # Use home router DNS so wrenspace.dev subdomains resolve internally
      "--resolv-conf=/etc/k3s-resolv.conf"
      # Allow kubectl to connect via MetalLB VIP (192.168.200.100)
      "--tls-san=192.168.200.102"
      # Relax leader-election deadlines so controller-manager and
      # scheduler don't lose their leases (and crash k3s) when the
      # apiserver is briefly slow under cold-start pod-storm load.
      # Defaults are 15s/10s/2s; this is a single-node cluster so
      # slower failover doesn't matter.
      "--kube-controller-manager-arg=leader-elect-lease-duration=45s"
      "--kube-controller-manager-arg=leader-elect-renew-deadline=30s"
      "--kube-controller-manager-arg=leader-elect-retry-period=10s"
      "--kube-scheduler-arg=leader-elect-lease-duration=45s"
      "--kube-scheduler-arg=leader-elect-renew-deadline=30s"
      "--kube-scheduler-arg=leader-elect-retry-period=10s"
      # Throttle concurrent image pulls so cold-boot doesn't spike
      # CPU and saturate the apiserver with status updates.
      "--kubelet-arg=registry-pull-qps=2"
      "--kubelet-arg=registry-burst=4"
    ];
  };
}
