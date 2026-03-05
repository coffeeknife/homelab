{ config, ... }:

{
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
    ];
  };
}
