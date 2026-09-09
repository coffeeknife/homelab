{ modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../../modules/common.nix
    ../../modules/disk.nix
    ../../modules/longhorn-prereqs.nix
    ../../modules/k3s-server.nix
  ];

  networking.hostName = "kube-vm";

  networking.interfaces.eth0.ipv4 = {
    addresses = [{ address = "192.168.200.2"; prefixLength = 24; }];
  };
  networking.defaultGateway = "192.168.200.1";

  # Single-node cluster; clusterInit enables embedded etcd so additional
  # nodes can join later if needed.
  services.k3s.clusterInit = true;

  # Intel HD630 QuickSync passthrough — label this node so GPU-dependent
  # workloads (e.g. Jellyfin) can schedule here via nodeAffinity/nodeSelector.
  # Was gpu=amd for the RX560 that retired with etheirys 2026-07-18; k3s only
  # applies --node-label at first registration, so an existing node also needs
  # `kubectl label node kube-vm gpu=intel --overwrite`.
  services.k3s.extraFlags = [ "--node-label gpu=intel" ];

  # Advertises the pod (10.42.0.0/16) and service (10.43.0.0/16) CIDRs as
  # Tailscale subnet routes so the external traefik LXC can reach in-cluster
  # backends without a route on the physical network. Route approval and the
  # ACL restricting which node may actually use the routes both happen in the
  # Tailscale admin console/policy file, not here.
  # One-time manual step after this is deployed (needs interactive login):
  #   sudo tailscale up --advertise-routes=10.42.0.0/16,10.43.0.0/16 --accept-dns=false --hostname=kube-vm
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "server";
  };

  # linux-firmware for the i915 GuC/HuC blobs (also covered the old Polaris 11).
  hardware.enableRedistributableFirmware = true;
  hardware.graphics.enable = true;

  swapDevices = [{ device = "/swapfile"; size = 4096; }];
  system.stateVersion = "25.05";
}
