{
  description = "Mac Pro 7,1 headless LLM inference server";

  inputs = {
    # Unstable gets you the freshest Mesa/RADV (Mesa 25.3+ has real RADV
    # compute gains) and current llama.cpp. Pin to 25.11 if you prefer stability.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    t2fanrd = {
      url = "github:GnomedDev/T2FanRD";
      # Follow the root nixpkgs so the cargo-vendor fetcher uses the
      # static.crates.io CDN endpoint; the old lock (2025 nixpkgs) hit
      # 403s from the deprecated crates.io/api download endpoint.
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # Binary cache so you DON'T recompile the T2-patched kernel (saves ~1h+).
  nixConfig = {
    extra-substituters = ["https://cache.soopy.moe"];
    extra-trusted-public-keys = [
      "cache.soopy.moe-1:0RZVsQeR+GOh0VQI9rvnHz55nVXkFardDqfm4+afjPo="
    ];
  };

  outputs = {
    self,
    nixpkgs,
    nixos-hardware,
    t2fanrd,
    ...
  }: {
    nixosConfigurations.macpro = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nixos-hardware.nixosModules.apple-t2 # all the T2 magic
        t2fanrd.nixosModules.t2fanrd
        ./hosts/macpro/default.nix
      ];
    };

  };
}
