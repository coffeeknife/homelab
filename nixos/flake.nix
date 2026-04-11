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
  };

  outputs = { self, nixpkgs, sops-nix, colmena, disko, ... }:
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
        kube-vm = mkHost { name = "kube-vm"; };
      };

      # colmena deployment configuration
      # Usage:
      #   colmena apply               -- deploy all nodes
      #   colmena apply --on kube-vm  -- deploy single node
      #   colmena exec -- systemctl restart k3s
      colmenaHive = colmena.lib.makeHive {
        meta = {
          nixpkgs = import nixpkgs { inherit system; };
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
      };

      # Dev shell with cluster management tools
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          colmena.packages.${system}.colmena
          pkgs.kubectl
          pkgs.fluxcd
          pkgs.sops
          pkgs.age
        ];
      };
    };
}
