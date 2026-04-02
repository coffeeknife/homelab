{ modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../../modules/common.nix
    ../../modules/disk.nix
    ../../modules/longhorn-prereqs.nix
    ../../modules/k3s-server.nix
  ];

  networking.hostName = "kube-1";

  networking.interfaces.eth0.ipv4 = {
    addresses = [{ address = "192.168.200.2"; prefixLength = 24; }];
  };
  networking.defaultGateway = "192.168.200.1";

  # kube-1 bootstraps the embedded etcd cluster; kube-2 and kube-3 join via serverAddr
  services.k3s.clusterInit = true;

}
