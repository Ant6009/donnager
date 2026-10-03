# hosts/donnager/nvidia.nix
#
# NVIDIA CMP 170HX (GA100) driver + community unlock, Nix-native.
#
# The unlock = 11 patches against open-gpu-kernel-modules, fed into nixpkgs'
# `patchesOpen` hook so that nvidia_x11.open IS the unlocked module:
#   - built in the Nix sandbox against the pinned T2 6.18.44 kernel
#     (headers from kernel.dev; no /lib/modules writes, no depmod, no
#     initramfs step, nothing machine-local)
#   - userspace (libcuda/nvidia-smi/CUDA), GSP firmware and persistenced
#     come from the same derivation -> automatic version lockstep
#   - `nixos-rebuild` can never drop or shadow it; it re-applies on a
#     kernel bump; rollback = remove patchesOpen + rebuild + cold boot
#
# Staging:
#   Stage 1: as committed (stock 610.57.04 open driver, no unlock).
#   Stage 2: uncomment `patchesOpen = cmpPatches;`  -> the unlock.
#   Stage 3: uncomment the two GEN2 blocks          -> PCIe Gen2.
{ config, pkgs, lib, ... }:

let
  # --- pinned unlock patchset ------------------------------------------------
  # Bump only deliberately: the patches are specific to the driver version
  # below (upstream verifies them in CI against its supported list).
  cmpunlocker = pkgs.fetchFromGitHub {
    owner = "amoghmunikote";
    repo = "cmpunlocker";
    rev = "88e39ce67488796b2c6c716fe8f9b4e6e943a55e"; # 2026-09-13, master
    hash = "sha256-52lIswLRWXwEskxkYaDK55w0giMzMReLgqX3RmQRU/4=";
  };

  # Application order is significant — matches cmpunlocker/driver/build.sh.
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
  # unlock. cmpunlocker accepts 615.71.09 / 610.57.04 / 610.43.03 /
  # 610.43.02 — anything else and the unlock is meaningless.
  nvidia = config.boot.kernelPackages.nvidiaPackages.mkDriver {
    version = "610.57.04";
    sha256_64bit       = "sha256-suk1xmuDuwDAyFe8jg7g/VLekoa0DJzB7sKafOfrEW0=";
    openSha256         = "sha256-rQHOOOY4KL92Ww3KDwh+j4eGU7oNAH8LutZC5wmFnPo=";
    settingsSha256     = "sha256-ZEMo8I8Zc2Tq6RVDNYpAH+f094dUaZiBqO+5f6lIjRI=";
    persistencedSha256 = "sha256-aXmD2VY1RLlgAnlHhOUMWzvMyhI6JTClcFLm4imF/mA=";

    # STAGE 2 — the unlock. Stock driver while commented out.
    # patchesOpen = cmpPatches;
  };
in
{
  # Headless, no X — but nixpkgs 26.11 gates hardware.nvidia.enabled on
  # this (the option is readOnly; default = "nvidia" in videoDrivers).
  # Without it the whole nvidia config is silently disabled.
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia.package = nvidia;
  hardware.nvidia.open = true;               # GA100: open modules only
  hardware.nvidia.modesetting.enable = true; # headless, no X/Wayland
#  hardware.nvidia.nvidia-persistenced.enable = true;

  # 64 GB BAR1 after unlock needs large MMIO allocation; also keeps the
  # door open for VFIO passthrough (cmpunlocker supports it).
  boot.kernelParams = [ "intel_iommu=on" "iommu=pt" ];

  # STAGE 3 (GEN2) — registry dwords; what cmpunlocker's install.sh writes
  # to /etc/modprobe.d/cmp-pcie-gen2.conf. Inert while the link is Gen1.
  # hardware.nvidia.moduleParams.nvidia = {
  #   NVreg_RegistryDwords = "RmForceEnableGen2=1;RMPcieLinkSpeed=0x1";
  # };

  # nvidia-smi on PATH (the driver package is not in systemPackages by default).
  environment.systemPackages = [ nvidia.bin ];

  # Power limit + persistence mode. Final value from the Stage 2 thermal
  # soak: 200 W on the 600 W PSU, 250 W after a 1450 W upgrade.
#  systemd.services.nvidia-powerlimit = {
#    description = "CMP170HX power limit + persistence mode";
#    wantedBy = [ "multi-user.target" ];
#    after = [ "hardware.nvidia.nvidiaPersistenced = true" ];
#    serviceConfig = { Type = "oneshot"; User = "root"; };
#    script = ''
#      ${nvidia.bin}/bin/nvidia-smi -pm 1
#      ${nvidia.bin}/bin/nvidia-smi -pl 200
#    '';
#  };
  #
  # STAGE 3 (GEN2) — early-boot retrain hammer.
  # Port of cmpunlocker tools/hammer.sh + systemd/gen2.service (pinned rev).
  # Patch 0007 opens a Gen2 window ~8-14 s after boot while GSP
  # bootstraps; this fires root-port retrains every 50 ms until the link
  # catches it (verified field behaviour: success around iteration 30).
  # No-op (exit 0) when no 10de:20c2/2082 is present. Log: /var/log/gen2.log.
  # systemd.services.cmp170hx-gen2 = {
  #   description = "CMP 170HX early-boot PCIe Gen2 retrain";
  #   wantedBy = [ "sysinit.target" ];
  #   after = [ "sysinit.target" ];
  #   before = [ "basic.target" ];
  #   serviceConfig = {
  #     DefaultDependencies = false;
  #     Type = "oneshot";
  #     TimeoutStartSec = 45;
  #     RemainAfterExit = false;
  #     User = "root";
  #   };
  #   script = ''
  #     set -uo pipefail
  #     LSPCI="${pkgs.pciutils}/bin/lspci"
  #     SETPCI="${pkgs.pciutils}/bin/setpci"
  #     LOG=/var/log/gen2.log
  #     TARGET_GEN=2
  #     MAX_ITER=600
  #     INTERVAL=0.05
  #     log() { echo "[$(date -Is)] $*" | tee -a "$LOG"; }
  #     gen() {
  #       local s
  #       s="$($SETPCI -s "$1" CAP_EXP+12.w 2>/dev/null || true)"
  #       [[ "$s" =~ ^[[:xdigit:]]{4}$ ]] && echo $((0x$s & 0x0f)) || echo "?"
  #     }
  #     : > "$LOG"
  #     mapfile -t gpus < <(
  #       "$LSPCI" -D -d 10de:20c2 2>/dev/null;
  #       "$LSPCI" -D -d 10de:2082 2>/dev/null
  #     )
  #     [[ ${#gpus[@]} -eq 0 ]] && { log "no CMP 170HX found; nothing touched"; exit 0; }
  #     rc=0
  #     for gpu in "${gpus[@]}"; do
  #       bridge="$(basename "$(dirname "$(readlink -f /sys/bus/pci/devices/$gpu)")")"
  #       [[ "$(cat /sys/bus/pci/devices/$bridge/class 2>/dev/null)" == 0x0604* ]] \
  #         || { log "$gpu: no PCI bridge upstream; skipping"; rc=1; continue; }
  #       cur="$(gen "$gpu")"
  #       if [[ "$cur" =~ ^[0-9]+$ ]] && (( cur >= TARGET_GEN )); then
  #         log "$gpu: already Gen$cur; no retrain needed"
  #         continue
  #       fi
  #       log "$gpu: start via $bridge (Gen$cur -> Gen$TARGET_GEN)"
  #       ok=0
  #       for ((i = 1; i <= MAX_ITER; i++)); do
  #         $SETPCI -s "$bridge" CAP_EXP+30.w=0002:000f 2>/dev/null || true
  #         $SETPCI -s "$gpu"    CAP_EXP+30.w=0002:000f 2>/dev/null || true
  #         $SETPCI -s "$bridge" CAP_EXP+10.w=0020:0020 2>/dev/null || true
  #         g="$(gen "$gpu")"
  #         if [[ "$g" =~ ^[0-9]+$ ]] && (( g >= TARGET_GEN )); then
  #           log "$gpu: SUCCESS Gen$g at iteration $i"
  #           ok=1
  #           break
  #         fi
  #         sleep "$INTERVAL"
  #       done
  #       if [[ $ok -eq 0 ]]; then
  #         log "$gpu: no Gen2 window caught after $MAX_ITER attempts; final Gen$(gen "$gpu")"
  #         rc=1
  #       fi
  #     done
  #     log "early retrain finished (rc=$rc)"
  #     exit $rc
  #   '';
  # };
}
