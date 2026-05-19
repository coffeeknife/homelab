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
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
  };

  outputs = { self, nixpkgs, sops-nix, colmena, disko, nixos-hardware, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
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

        gallifrey = nixpkgs.lib.nixosSystem {
          system  = "aarch64-linux";
          modules = [
            sops-nix.nixosModules.sops
            nixos-hardware.nixosModules.raspberry-pi-4
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
          nodeNixpkgs = {
            gallifrey = import nixpkgs { system = "aarch64-linux"; };
          };
          specialArgs = { inherit sops-nix; };
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
            targetUser = "robin";
            # robin is in the wheel group; sudo asks for a password.
            # Drive `colmena apply --on gallifrey` from a terminal so the
            # prompt lands locally (or set NOPASSWD in a future deploy
            # by toggling security.sudo.wheelNeedsPassword in common.nix).
            privilegeEscalationCommand = [ "sudo" "-H" "--" ];
            # Build the aarch64 closure on the dev machine via binfmt/qemu-user-static,
            # then push the pre-built result to gallifrey for activation only.
          };
          imports = [
            sops-nix.nixosModules.sops
            nixos-hardware.nixosModules.raspberry-pi-4
            ./hosts/gallifrey/default.nix
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
