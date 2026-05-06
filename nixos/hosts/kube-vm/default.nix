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

  # AMD GPU passthrough — label this node so GPU-dependent workloads
  # (e.g. Jellyfin) can schedule here via nodeAffinity/nodeSelector.
  services.k3s.extraFlags = [ "--node-label gpu=amd" ];

  # Polaris 11 (RX 460) requires linux-firmware for polaris11_sdma.bin etc.
  hardware.enableRedistributableFirmware = true;
  hardware.graphics.enable = true;

}
