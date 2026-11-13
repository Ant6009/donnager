{ config, pkgs, ... }:

# GPU setup: NVIDIA CMP 170HX only.
#
# Nothing on this box uses the Radeon Pro Vega II: llama-server runs from
# pkgs.llama-cpp-cuda with `--device CUDA0`, and strata is a CUDA build
# (docs/strata.md). The card is being sold, so this module no longer
# configures AMD/RADV at all.
#
# hardware.graphics.enable is still required, not for rendering but because
# the NVIDIA driver's libcuda.so has to be reachable through
# /run/opengl-driver/lib (docs/strata.md:64, strata.nix LD_LIBRARY_PATH).
#
# `package` overrides nixpkgs' `hardware.graphics.package = mkDefault pkgs.mesa`
# (nixos/modules/hardware/graphics.nix:144) with just the GLVND dispatch layer.
# Verified with `nix why-depends`: mesa entered the system closure through one
# path only (etc -> tmpfiles.d -> graphics-driver.conf -> graphics-drivers ->
# mesa, ~1.07 GB). The vendor libraries (libcuda, libGLX_nvidia, GBM, Vulkan
# ICD) come from the nvidia module's extraPackages
# (nixos/modules/hardware/video/nvidia.nix:503), so they are unaffected.
#
# Roll back with:
#   nixos-rebuild --rollback --target-host donnager
# and to bring AMD back: package = pkgs.mesa, plus radeontop / vulkan-tools in
# environment.systemPackages.
{
  hardware.graphics = {
    enable = true;
    package = pkgs.libglvnd;
  };

  # T2 wifi/bt firmware comes from nixos-hardware's own brcm-firmware package;
  # this covers the rest (NIC etc.). Not related to mesa.
  hardware.enableRedistributableFirmware = true;
}
