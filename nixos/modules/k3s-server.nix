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

  services.k3s = {
    enable    = true;
    role      = "server";
    tokenFile = config.sops.secrets.k3s-token.path;

    extraFlags = [
      # Disable components managed by Flux instead
      "--disable=traefik"
      "--disable=servicelb"
      "--disable=local-storage"
      # Relax etcd timeouts for Proxmox VM disks which can have variable fsync latency
      "--etcd-arg=heartbeat-interval=500"
      "--etcd-arg=election-timeout=5000"
      # Use home router DNS so wrenspace.dev subdomains resolve internally
      "--resolv-conf=/etc/k3s-resolv.conf"
      # Allow kubectl to connect via MetalLB VIP (192.168.200.100)
      "--tls-san=192.168.200.102"
    ];
  };
}
