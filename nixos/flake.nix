{
  description = "NixOS configuration for wrenspace.dev k3s cluster";

  inputs = {
    nixpkgs.url     = "github:nixos/nixpkgs/nixos-unstable";
    sops-nix.url    = "github:mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    disko.url       = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, sops-nix, disko, ... }:
    let
      system = "x86_64-linux";
      pkgs   = nixpkgs.legacyPackages.${system};

      mkHost = { name, extraModules ? [] }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            sops-nix.nixosModules.sops
            disko.nixosModules.disko
            ./hosts/${name}/default.nix
          ] ++ extraModules;
        };
    in
    {
      nixosConfigurations = {
        kube-1 = mkHost { name = "kube-1"; };
        kube-2 = mkHost { name = "kube-2"; };
        kube-3 = mkHost { name = "kube-3"; };
      };

      # colmena deployment configuration
      # Usage:
      #   colmena apply              -- deploy all nodes
      #   colmena apply --on kube-1  -- deploy single node
      #   colmena exec -- systemctl restart k3s
      colmenaHive = {
        meta = {
          nixpkgs = import nixpkgs { inherit system; };
          specialArgs = { inherit sops-nix; };
        };

        kube-1 = { ... }: {
          deployment = {
            targetHost = "192.168.200.2";
            targetUser = "root";
          };
          imports = [
            sops-nix.nixosModules.sops
            disko.nixosModules.disko
            ./hosts/kube-1/default.nix
          ];
        };

        kube-2 = { ... }: {
          deployment = {
            targetHost = "192.168.200.3";
            targetUser = "root";
          };
          imports = [
            sops-nix.nixosModules.sops
            disko.nixosModules.disko
            ./hosts/kube-2/default.nix
          ];
        };

        kube-3 = { ... }: {
          deployment = {
            targetHost = "192.168.200.4";
            targetUser = "root";
          };
          imports = [
            sops-nix.nixosModules.sops
            disko.nixosModules.disko
            ./hosts/kube-3/default.nix
          ];
        };
      };

      # Dev shell with cluster management tools
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.colmena
          pkgs.kubectl
          pkgs.fluxcd
          pkgs.sops
          pkgs.age
        ];
      };
    };
}
