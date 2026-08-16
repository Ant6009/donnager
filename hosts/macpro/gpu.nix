{pkgs, ...}: {
  # Mesa RADV is the default Vulkan driver on 64-bit; just enable graphics.
  hardware.graphics.enable = true;

  # Vega II fires up amdgpu; make sure early KMS is available.
  hardware.amdgpu.initrd.enable = true;

  # Force RADV in case AMDVLK ever gets pulled in — RADV is what we want here.
  environment.variables.AMD_VULKAN_ICD = "RADV";

  # Redistributable firmware (amdgpu Vega20 microcode) — usually implied, but
  # be explicit on an appliance.
  hardware.enableRedistributableFirmware = true;

  # control GPU fans
  services.lact.enable = true;
  hardware.amdgpu.overdrive.enable = true;
}
