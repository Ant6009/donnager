{
  description = "Mac Pro 7,1 headless LLM inference server";

  inputs = {
    # Userspace: llama.cpp/llama-swap, open-webui, searxng, caddy. The old
    # justification (freshest Mesa/RADV for llama.cpp compute) no longer
    # applies: inference is CUDA-only on the CMP 170HX and mesa is out of the
    # closure (hosts/donnager/gpu.nix). Bump it deliberately, on its own, as
    # its own commit — `nix flake update nixpkgs`. Fast-moving LLM tooling
    # should come from `llmNixpkgs` instead so this input can stay put.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # FROZEN kernel source. The T2 kernel is built from nixpkgs' linux_6_18,
    # and the t2linux patches (pinned in nixos-hardware) only apply up to a
    # given 6.18.y. 0ae2bc14 -> linux_6_18 = 6.18.44, the last known-good.
    # Bump this input ONLY after verifying the new 6.18.y kernel still builds;
    # never run bare `nix flake update` (it would move this too). What a bare
    # update drags along: this kernel, `nixpkgs` userspace (llama-cpp, mesa,
    # open-webui, python, nix), and the cargo builds of t2fanrd/fortytwo, whose
    # nixpkgs `follows = "nixpkgs"`.
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

    # 42 — local-network Perplexity-style answer engine (LLM + SearXNG glue).
    fortytwo = {
      url = "github:Ant6009/42";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Pinned second nixpkgs, for fast-moving LLM tooling only: open-terminal
    # now, and open-webui / llama-cpp-cuda later if you want a newer one
    # without a userspace bump of the main input. Update it on its own with
    #   nix flake update llmNixpkgs
    # so `nixpkgs` (and the frozen kernel input) never move as a side effect.
    llmNixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  # Binary cache so you DON'T recompile the T2-patched kernel (saves ~1h+).
  nixConfig = {
    extra-substituters = ["https://cache.soopy.moe"];
    extra-trusted-public-keys = [
      "cache.soopy.moe-1:0RZVsQeR+GOh0VQI9rvnHz55nVXkFardDqfm4+afjPo="
    ];
  };

  outputs = { self, nixpkgs, nixpkgs-frozen, nixos-hardware, t2fanrd, agenix, fortytwo, llmNixpkgs, ... }:
  let
    system = "x86_64-linux";

    # open-terminal does not exist in the locked main nixpkgs (2026-10-23), so
    # the LLM-tooling packages come from `llmNixpkgs`. Modules receive this
    # instantiated set as `llmPkgs` (see hosts/donnager/open-terminal.nix).
    llmPkgs = import llmNixpkgs {
      inherit system;
      config.allowUnfree = true;
    };

    # Build the T2 kernel AND all of its modules from the frozen nixpkgs so
    # the kernel stays at 6.18.44 no matter how far `nixpkgs` (userspace)
    # rolls. Kept self-consistent (one kernel -> one module set -> one initrd).
    frozenPkgs = (import nixpkgs-frozen {
      inherit system;
      # The nvidia driver (unfree) builds from this instance via
      # boot.kernelPackages.nvidiaPackages; allow it here too.
      config.allowUnfree = true;
    });
    t2Kernel = frozenPkgs.callPackage (
      nixos-hardware.outPath + "/apple/t2/pkgs/linux-t2"
    ) { };
    t2KernelPackages = frozenPkgs.linuxPackagesFor t2Kernel;
  in
  {
    nixosConfigurations.donnager = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit llmPkgs; };
      modules = [
        nixos-hardware.nixosModules.apple-t2 # all the T2 magic
        t2fanrd.nixosModules.t2fanrd
        agenix.nixosModules.default
        fortytwo.nixosModules.default
        ./hosts/donnager/default.nix
        # Override AFTER apple-t2 (mkForce) so the frozen 6.18.44 kernel wins
        # over the kernelChannel apple-t2 would otherwise select from `nixpkgs`.
        ({ lib, ... }: { boot.kernelPackages = lib.mkForce t2KernelPackages; })
      ];
    };

    # Build shell for Project Maya's CUDA engines (docs/maya.md §3): nvcc,
    # libcublas (CMakeLists.txt links CUDA::cublas), and a host compiler nvcc
    # will take. nixpkgs' stdenv here is gcc 16.2, which nvcc refuses, and Maya
    # only probes the default g++ plus /usr/bin/g++-N (maya.py toolchain_for),
    # so gcc13 goes first on PATH and as CC/CXX.
    #
    # Build shell only: Maya's engine, .venv and ~245 GB of models live
    # out-of-tree in /home/maya (hosts/donnager/maya.nix), the same way strata
    # lives in /var/lib/strata. cudaPackages repackages NVIDIA's own tarballs,
    # so this is a multi-GB download, not a compile.
    devShells."${system}".maya = llmPkgs.mkShell {
      description = "Project Maya build shell (nvcc for sm_80, gcc 13 host compiler)";
      packages = [
        llmPkgs.cudaPackages.cuda_nvcc
        llmPkgs.cudaPackages.cuda_cudart
        llmPkgs.cudaPackages.libcublas
        # CUDA 13 splits the profiler API out of cudart and nixpkgs packages it
        # separately. src/core/glm_fast_path.cu includes cuda_profiler_api.h, so
        # the Qwen-family engine (strata_engine) stopped at "fatal error:
        # cuda_profiler_api.h: No such file or directory" while the Hy4 engine
        # built fine - its sources do not include that header. nvtx3/nvToolsExt.h
        # (same file, line 49) is cuda_nvtx, and stopped it again one compile
        # later. The whole CUDA include set Maya's sources ask for, measured:
        # cuda.h, cuda_runtime.h, cuda_fp16.h, cuda_bf16.h, cuda_fp8.h (nvcc +
        # cudart), cublas_v2.h (libcublas), cuda_profiler_api.h, nvToolsExt.h.
        llmPkgs.cudaPackages.cuda_profiler_api
        llmPkgs.cudaPackages.cuda_nvtx
        llmPkgs.gcc13
        llmPkgs.cmake
        llmPkgs.ninja
        llmPkgs.gnumake
        llmPkgs.python3
        llmPkgs.git
        llmPkgs.pkg-config
      ];
      CC = "${llmPkgs.gcc13}/bin/gcc";
      CXX = "${llmPkgs.gcc13}/bin/g++";
      shellHook = ''
        export PATH="${llmPkgs.gcc13}/bin:$PATH"
        export CC="${llmPkgs.gcc13}/bin/gcc"
        export CXX="${llmPkgs.gcc13}/bin/g++"
        nvcc --version | sed -n 's/.*release \([0-9.]*\).*/nvcc \1/p' | head -1
        echo "gcc: $(g++ --version | head -1)"
        echo "Maya takes the CUDA arch from this PC's GPUs (sm_80 here); pass --host-compiler g++ if it ever rejects this one."
      '';
    };
  };
}
