{
  description = "Mac Pro 7,1 headless LLM inference server";

  inputs = {
    # Rolling userspace: freshest Mesa/RADV (25.3+ has real RADV compute
    # gains) and current llama.cpp.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # FROZEN kernel source. The T2 kernel is built from nixpkgs' linux_6_18,
    # and the t2linux patches (pinned in nixos-hardware) only apply up to a
    # given 6.18.y. 0ae2bc14 -> linux_6_18 = 6.18.44, the last known-good.
    # Bump this input ONLY after verifying the new 6.18.y kernel still builds;
    # never run bare `nix flake update` (it would move this too).
    nixpkgs-frozen.url = "github:NixOS/nixpkgs/0ae2bc1419c3f345984c2629e72e7a631820fa4d";

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    t2fanrd = {
      url = "github:GnomedDev/T2FanRD";
      # Follow the root nixpkgs so the cargo-vendor fetcher uses the
      # static.crates.io CDN endpoint; the old lock (2025 nixpkgs) hit
      # 403s from the deprecated crates.io/api download endpoint.
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # age-encrypted secrets; decrypted at activation with the machine's
    # SSH host key (module default identity). See secrets/.
    agenix.url = "github:ryantm/agenix";
  };

  # Binary cache so you DON'T recompile the T2-patched kernel (saves ~1h+).
  nixConfig = {
    extra-substituters = ["https://cache.soopy.moe"];
    extra-trusted-public-keys = [
      "cache.soopy.moe-1:0RZVsQeR+GOh0VQI9rvnHz55nVXkFardDqfm4+afjPo="
    ];
  };

  outputs = { self, nixpkgs, nixpkgs-frozen, nixos-hardware, t2fanrd, agenix, ... }:
  let
    system = "x86_64-linux";

    # Build the T2 kernel AND all of its modules from the frozen nixpkgs so
    # the kernel stays at 6.18.44 no matter how far `nixpkgs` (userspace)
    # rolls. Kept self-consistent (one kernel -> one module set -> one initrd).
    frozenPkgs = nixpkgs-frozen.legacyPackages.${system};
    t2Kernel = frozenPkgs.callPackage (
      nixos-hardware.outPath + "/apple/t2/pkgs/linux-t2"
    ) { };
    t2KernelPackages = frozenPkgs.linuxPackagesFor t2Kernel;
  in
  {
    nixosConfigurations.donnager = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        nixos-hardware.nixosModules.apple-t2 # all the T2 magic
        t2fanrd.nixosModules.t2fanrd
        agenix.nixosModules.default
        ./hosts/donnager/default.nix
        # Override AFTER apple-t2 (mkForce) so the frozen 6.18.44 kernel wins
        # over the kernelChannel apple-t2 would otherwise select from `nixpkgs`.
        ({ lib, ... }: { boot.kernelPackages = lib.mkForce t2KernelPackages; })
      ];
    };
  };
}
