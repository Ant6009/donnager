# hosts/donnager/nvidia.nix
#
# NVIDIA CMP 170HX (GA100) driver + community unlock, Nix-native.
#
# The unlock = 11 patches against open-gpu-kernel-modules, fed into nixpkgs'
# `patchesOpen` hook so that nvidia_x11.open IS the unlocked module:
#   - built in the Nix sandbox against the pinned kernel (no /lib/modules
#     writes, no depmod, no initramfs step, nothing machine-local)
#   - userspace (libcuda/nvidia-smi/CUDA), GSP firmware and persistenced come
#     from the same derivation -> automatic version lockstep
#   - `nixos-rebuild` can never drop or shadow it; it re-applies on a kernel
#     bump (install.sh's "re-run after each kernel upgrade" does not apply);
#     rollback = unlock = false + rebuild + COLD boot
#
# This replaces what cmpunlocker's install.sh + driver/build.sh do by hand
# (root/GPU/Secure Boot/driver-version/headers checks, tarball download, patch,
# build, install to updates/cmpunlocker, depmod, initramfs, hot reload, DKMS
# removal, modprobe file, IOMMU cmdline, Gen2 service).
#
# Things Nix does NOT do for you:
#   - Secure Boot must be off: the patched modules are unsigned.
#   - A COLD boot (full power off, then on) after the first switch.
#   - IOMMU (VT-d) must be enabled in firmware for the iommu kernel params.
#   - VM passthrough prep (tools/passthrough-setup.sh) is NOT replicated;
#     only needed if you hand the card to vfio-pci.
#
# Staging (flip the booleans below, rebuild, cold boot, verify):
#   Stage 1: unlock = false, gen2 = false  -> stock 610.57.04 open driver.
#   Stage 2: unlock = true                 -> the unlock. NOTE this also sets
#            the Gen2 registry dwords, as install.sh always does (the two
#            pcie-gen2 patches are part of the set either way).
#   Stage 3: gen2 = true                   -> early-boot Gen2 retrain service.
#
# Verify stage 2:  sudo dmesg | grep SEC2_DEBUG
#   want: "saved stock signature", a POST-WRITE line with SS0=0x88888888
#   SS1=0x00000008 and (8 GB card, 10de:20c2) CFG1=0x02779000 LMR=0x0000020b,
#   "late PMA extension status=0x0"; nvidia-smi ~65536 MiB (10 GB card: ~40960).
#   Per-attempt Booter status 0xffff and a missing dmem.bin are normal.
# Verify stage 3:
#   nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.gen.max --format=csv
#   (expect 2,2) and /var/log/gen2.log.
{ config, pkgs, lib, ... }:

let
  # --- stage switches --------------------------------------------------------
  unlock = true;  # STAGE 2: apply the unlock patchset (+ Gen2 registry dwords)
  gen2 = true;    # STAGE 3: early-boot PCIe Gen2 retrain service

  # Set to a number of watts to install a oneshot that applies a power limit
  # (200 on the 600 W PSU, 250 after the 1450 W upgrade). null = don't.
  powerLimitWatts = null;

  # --- pinned unlock patchset ------------------------------------------------
  # Bump only deliberately: the patches are specific to the driver version
  # below. Before bumping, check driver/VERSION in the pinned rev lists it
  # (install.sh/build.sh hard-fail on any version not in that file).
  cmpunlocker = pkgs.fetchFromGitHub {
    owner = "amoghmunikote";
    repo = "cmpunlocker";
    rev = "88e39ce67488796b2c6c716fe8f9b4e6e943a55e"; # 2026-09-13, master
    hash = "sha256-52lIswLRWXwEskxkYaDK55w0giMzMReLgqX3RmQRU/4=";
  };

  # Names and order are identical to PATCH_ORDER in driver/build.sh, which
  # applies them with `patch -p1` under `set -e`. A hunk that fails aborts the
  # Nix build the same way (loudly, in the sandbox), never silently.
  cmpPatches = map (name: "${cmpunlocker}/driver/patches/${name}") [
    "sec2-postbl-plm-ss-cfg.patch"    # core: 4x PLM open via Booter_Load
                                      # pre-GSP, SS0/SS1 + CFG1/LMR writes,
                                      # fb_length (runtime per PCI ID)
    "booter-verify.patch"             # SEC2_DEBUG kernel log trail
    "late-pma.patch"                  # register the [8GB, 64GB] FB region
    "bar0-pramin-clamp.patch"         # clamp BAR0/PRAMIN to stock 8GB
    "ce-scrub-workarounds.patch"      # CE scrub PTE-kind + VAS fixes
    "persistent-sw-state.patch"       # NV_FLAG_PERSISTENT_SW_STATE
    "pcie-gen2.patch"                 # GEN2: register sequence pre-GSP
    "pcie-gen2-probe-retrain.patch"   # GEN2: retrain at probe
    "name-string.patch"               # nvidia-smi: "NVIDIA CMP 170HX"
    "bar1-resize-unlock.patch"        # resize BAR1 to the unlocked size
    "cmp-sku-mask.patch"              # hide the CMP SKU flag from userspace
  ];

  # --- driver ----------------------------------------------------------------
  # 610.57.04 == `new_feature` on both the frozen (0ae2bc1419c3) and rolling
  # (d6524aaca2ff) nixpkgs; hashes copied verbatim from
  # pkgs/os-specific/linux/nvidia-x11/default.nix. Pinned here (not via the
  # branch attribute) so a flake update cannot move the driver under the
  # unlock. The unlock is only meaningful on versions listed in the pinned
  # rev's driver/VERSION. The in-driver gate only fires for PCI IDs 10de:20c2
  # (8 GB) and 10de:2082 (10 GB); a 10de:20b0 card gets patched modules that
  # never activate.
  nvidia = config.boot.kernelPackages.nvidiaPackages.mkDriver ({
    version = "610.57.04";
    sha256_64bit       = "sha256-suk1xmuDuwDAyFe8jg7g/VLekoa0DJzB7sKafOfrEW0=";
    openSha256         = "sha256-rQHOOOY4KL92Ww3KDwh+j4eGU7oNAH8LutZC5wmFnPo=";
    settingsSha256     = "sha256-ZEMo8I8Zc2Tq6RVDNYpAH+f094dUaZiBqO+5f6lIjRI=";
    persistencedSha256 = "sha256-aXmD2VY1RLlgAnlHhOUMWzvMyhI6JTClcFLm4imF/mA=";
  } // lib.optionalAttrs unlock {
    patchesOpen = cmpPatches;
  });

  # --- Gen2 retrain ----------------------------------------------------------
  # Run the repo's own tools/hammer.sh from the pinned rev instead of a port,
  # so it can't drift. The only change: its hardcoded FHS PATH (no /usr/bin on
  # NixOS) is replaced with store paths. --replace-fail makes the build fail
  # loudly if that line ever changes upstream. It needs lspci/setpci, awk and
  # coreutils (date, basename, dirname, readlink, sleep). Log: /var/log/gen2.log.
  gen2Hammer = pkgs.runCommand "cmp170hx-gen2-hammer" { } ''
    install -Dm755 ${cmpunlocker}/tools/hammer.sh $out/bin/hammer
    substituteInPlace $out/bin/hammer --replace-fail \
      'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
      'PATH=${lib.makeBinPath [ pkgs.pciutils pkgs.coreutils pkgs.gawk ]}'
    patchShebangs $out/bin/hammer
  '';
in
{
  assertions = [
    {
      assertion = !gen2 || unlock;
      message = "nvidia.nix: gen2 = true needs unlock = true (the Gen2 window only exists in the patched driver).";
    }
  ];

  # Headless, no X — but nixpkgs 26.11 gates hardware.nvidia.enabled on
  # this (the option is readOnly; default = "nvidia" in videoDrivers).
  # Without it the whole nvidia config is silently disabled.
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia.package = nvidia;
  hardware.nvidia.open = true;               # GA100: open modules only
  hardware.nvidia.modesetting.enable = true; # headless, no X/Wayland
  # persistent-sw-state.patch replaces the old watchdog daemon, so
  # nvidia-persistenced is not needed for the unlock.
  # hardware.nvidia.nvidia-persistenced.enable = true;

  # Same as install.sh's IOMMU step for an Intel CPU (Mac Pro 7,1 = Xeon W):
  # intel_iommu=on iommu=pt. Also needed for 64 GB BAR1 / VFIO. VT-d must be
  # enabled in firmware.
  boot.kernelParams = [ "intel_iommu=on" "iommu=pt" ];

  # nvidia-smi on PATH (the driver package is not in systemPackages by default).
  environment.systemPackages = [ nvidia.bin ];

  # install.sh writes this to /etc/modprobe.d/cmp-pcie-gen2.conf
  # unconditionally (even with --no-gen2-service), so it goes with the unlock.
  # To defer it to Stage 3, change `unlock` to `gen2` here.
  boot.extraModprobeConfig = lib.mkIf unlock ''
    options nvidia NVreg_RegistryDwords="RmForceEnableGen2=1;RMPcieLinkSpeed=0x1"
  '';

  # STAGE 3 (GEN2) — early-boot retrain. The patched driver opens a short Gen2
  # window while GSP bootstraps; hammer.sh fires root-port retrains every 50 ms
  # (600 attempts max) until the link catches it. No-op when no 10de:20c2 /
  # 10de:2082 is present. Exits 1 (unit shows failed) if the window is missed.
  #
  # DefaultDependencies is a [Unit] key (unitConfig, not serviceConfig); left
  # on, systemd adds After=basic.target and Before=basic.target would cycle.
  # Ordering/wantedBy are carried over from your earlier file (taken from the
  # repo's gen2.service); tools/service.sh was not available to re-check them.
  # TimeoutStartSec is 90 rather than 45: 600 iterations of sleep + 4 setpci
  # calls can take 40-60 s per GPU when the window is never caught.
  # Recovery: boot with systemd.mask=cmp170hx-gen2.service (or pick the
  # previous generation).
  systemd.services.cmp170hx-gen2 = lib.mkIf (unlock && gen2) {
    description = "CMP 170HX early-boot PCIe Gen2 retrain";
    wantedBy = [ "sysinit.target" ];
    after = [ "sysinit.target" ];
    before = [ "basic.target" "shutdown.target" ];
    conflicts = [ "shutdown.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${gen2Hammer}/bin/hammer";
      TimeoutStartSec = 90;
      RemainAfterExit = false;
      User = "root";
    };
  };

  # Optional power limit + persistence mode. Final value comes from the
  # Stage 2 thermal soak.
  systemd.services.nvidia-powerlimit = lib.mkIf (powerLimitWatts != null) {
    description = "CMP170HX power limit + persistence mode";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    serviceConfig = { Type = "oneshot"; User = "root"; };
    script = ''
      ${nvidia.bin}/bin/nvidia-smi -pm 1
      ${nvidia.bin}/bin/nvidia-smi -pl ${toString powerLimitWatts}
    '';
  };
}
