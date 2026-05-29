{
  description = "NixOS configuration for wrenspace.dev k3s cluster";

  inputs = {
    nixpkgs.url     = "github:nixos/nixpkgs/nixos-unstable";
    sops-nix.url    = "github:mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    colmena.url     = "github:zhaofengli/colmena?ref=refs/tags/v0.4.0";
    colmena.inputs.nixpkgs.follows = "nixpkgs";
    disko.url       = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    # gallifrey (Raspberry Pi 4) uses nixos-raspberrypi for vendor kernel,
    # firmware, and bootloader. Its prebuilt aarch64 closure is published to
    # https://nixos-raspberrypi.cachix.org so the Pi never has to compile
    # the kernel locally. Pinned to its own nixpkgs (nixos-25.11) to keep
    # cache hits — see nodeNixpkgs.gallifrey below.
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";
  };

  outputs = { self, nixpkgs, sops-nix, colmena, disko, nixos-raspberrypi, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      rpiPkgs = import nixos-raspberrypi.inputs.nixpkgs { system = "aarch64-linux"; };
    in
    {
      nixosConfigurations = {
        kube-vm = nixpkgs.lib.nixosSystem {
          system  = "x86_64-linux";
          modules = [
            sops-nix.nixosModules.sops
            disko.nixosModules.disko
            ./hosts/kube-vm/default.nix
          ];
        };

        gallifrey = nixos-raspberrypi.lib.nixosSystem {
          specialArgs = { inherit sops-nix; };
          modules = [
            sops-nix.nixosModules.sops
            nixos-raspberrypi.nixosModules.raspberry-pi-4.base
            ./hosts/gallifrey/hardware-configuration.nix
            ./hosts/gallifrey/default.nix
          ];
        };

        vulcan = nixos-raspberrypi.lib.nixosSystem {
          specialArgs = { inherit sops-nix; };
          modules = [
            sops-nix.nixosModules.sops
            nixos-raspberrypi.nixosModules.raspberry-pi-4.base
            ./hosts/vulcan/hardware-configuration.nix
            ./hosts/vulcan/default.nix
          ];
        };

        # One-shot SD/USB installer images. Same host config as the runtime
        # system, but the sd-image module replaces hardware-configuration.nix
        # and produces system.build.sdImage (the .img.zst file to dd onto
        # the target media). Build with:
        #   nix build .#nixosConfigurations.<host>-installer.config.system.build.sdImage
        vulcan-installer = nixos-raspberrypi.lib.nixosSystem {
          specialArgs = { inherit sops-nix; };
          modules = [
            sops-nix.nixosModules.sops
            nixos-raspberrypi.nixosModules.raspberry-pi-4.base
            nixos-raspberrypi.nixosModules.sd-image
            ./hosts/vulcan/default.nix
          ];
        };

        gallifrey-installer = nixos-raspberrypi.lib.nixosSystem {
          specialArgs = { inherit sops-nix; };
          modules = [
            sops-nix.nixosModules.sops
            nixos-raspberrypi.nixosModules.raspberry-pi-4.base
            nixos-raspberrypi.nixosModules.sd-image
            ./hosts/gallifrey/default.nix
          ];
        };
      };

      # colmena deployment configuration
      # Usage:
      #   colmena apply                -- deploy all nodes
      #   colmena apply --on kube-vm   -- deploy single node
      #   colmena apply --on gallifrey -- deploy the Pi
      #   colmena exec -- systemctl restart k3s
      colmenaHive = colmena.lib.makeHive {
        meta = {
          nixpkgs = import nixpkgs { system = "x86_64-linux"; };
          # Use nixos-raspberrypi's pinned nixpkgs for gallifrey so derivations
          # hash-match the prebuilt artifacts on nixos-raspberrypi.cachix.org.
          nodeNixpkgs = {
            gallifrey = rpiPkgs;
            vulcan    = rpiPkgs;
          };
          specialArgs = { inherit sops-nix nixos-raspberrypi; };
        };

        kube-vm = { ... }: {
          deployment = {
            targetHost = "192.168.200.2";
            targetUser = "root";
          };
          imports = [
            sops-nix.nixosModules.sops
            disko.nixosModules.disko
            ./hosts/kube-vm/default.nix
          ];
        };

        gallifrey = { ... }: {
          deployment = {
            targetHost = "192.168.1.54";
            targetUser = "root";
            # Deploy as root (matches kube-vm) — avoids the sudo round-trip
            # for nix store ops and activation. root's SSH key comes from
            # common.nix users.users.root.openssh.authorizedKeys.keys.
          };
          imports = [
            sops-nix.nixosModules.sops
            # nixos-raspberrypi modules: vendor kernel + firmware + bootloader
            # plus the inject-overlays glue (required when not using their
            # nixosSystem helper) and trusted-nix-caches (adds the cachix).
            nixos-raspberrypi.nixosModules.raspberry-pi-4.base
            nixos-raspberrypi.nixosModules.trusted-nix-caches
            nixos-raspberrypi.lib.inject-overlays
            ./hosts/gallifrey/hardware-configuration.nix
            ./hosts/gallifrey/default.nix
          ];
        };

        vulcan = { ... }: {
          deployment = {
            targetHost = "192.168.1.69";
            targetUser = "root";
          };
          imports = [
            sops-nix.nixosModules.sops
            nixos-raspberrypi.nixosModules.raspberry-pi-4.base
            nixos-raspberrypi.nixosModules.trusted-nix-caches
            nixos-raspberrypi.lib.inject-overlays
            ./hosts/vulcan/hardware-configuration.nix
            ./hosts/vulcan/default.nix
          ];
        };
      };

      # Dev shell with cluster management tools
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = [
          colmena.packages.x86_64-linux.colmena
          pkgs.kubectl
          pkgs.fluxcd
          pkgs.sops
          pkgs.age
        ];
      };
    };
}
