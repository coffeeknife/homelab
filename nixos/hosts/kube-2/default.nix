{ modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../../modules/common.nix
    ../../modules/disk.nix
    ../../modules/longhorn-prereqs.nix
    ../../modules/k3s-server.nix
  ];

  networking.hostName = "kube-2";

  networking.interfaces.eth0.ipv4 = {
    addresses = [{ address = "192.168.200.3"; prefixLength = 24; }];
  };
  networking.defaultGateway = "192.168.200.1";

  # Join the cluster bootstrapped by kube-1
  services.k3s.serverAddr = "https://192.168.200.2:6443";

  boot.loader.grub = {
    enable = true;
    device = "/dev/sda";
  };

}
