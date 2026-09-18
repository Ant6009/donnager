# Adding an NVIDIA CMP 170HX to donnager — work plan

Status: **planning**. Nothing in this doc has been executed yet.
Research current as of 2026-09-18 (sources in §9). Driver/unlock sections
rewritten 2026-09-18 against cmpunlocker master `88e39ce` and nixpkgs
`0ae2bc1419c3` (frozen) / `d6524aaca2ff` (rolling).

---

## 1. What the card is, and what we're buying

The CMP 170HX is a repurposed GA100 (A100-family) mining accelerator:

| Property | Value |
| --- | --- |
| Silicon | GA100 (Ampere, compute capability **8.0**) |
| Memory | HBM2e, physically 64 GB — factory-locked to **8 GB** (SKU `10de:20c2`) or **10 GB** (SKU `10de:2082`) |
| Unlock target | 8 GB card → **64 GB (65536 MiB)**; 10 GB card → **40 GB (40960 MiB)**. 80 GB on 10 GB cards was tried and rejected as unstable |
| Interface | PCIe 4.0, but ships **x4** with lanes 5–16 de-populated; trains at **Gen1** (2.5 GT/s) out of the box |
| Bandwidth | ~0.85 GB/s host↔device at Gen1 x4 (measured); ~1.6–1.7 GB/s with the Gen2 software unlock |
| Display | **None.** Headless-only; one board reportedly refused to POST with only a 170HX fitted — the Vega II stays in for that reason |
| Cooling | **Fully passive, no fan on the card.** `Fan Speed: N/A`. It cannot protect itself |
| Power | One **8-pin EPS (CPU-style)** socket (two 12 V rails combined), 300 W rated. Ships with a 2× PCIe-8-pin → EPS Y-adapter. Stock firmware: 250 W default = max, 100 W min |
| ECC / NVLink / P2P | OTP-fuse disabled / absent — no known lever |

Two separate things are often conflated:

1. **Being driveable** — a stock 170HX works fine on ordinary NVIDIA drivers
   (reported on 570 + CUDA 12.8, 535-server, etc.). `nvidia-smi` names it
   "NVIDIA Graphics Device", 8 GB, compute capability 8.0. But compute is
   throttled (SM sections masked) and memory is 8/10 GB.
2. **Being unlocked** — the community unlock restores full SM compute
   throughput *and* the full HBM2e geometry. It works with a **patched
   nvidia-open** kernel module; current cmpunlocker supports driver versions
   **615.71.09, 610.57.04, 610.43.03, 610.43.02** (exact-version match).

Why it's interesting for donnager: a 64 GB CUDA device at mining-card prices,
usable by llama.cpp (SM80 tensor cores work unmodified) and vLLM. Measured
single-card numbers (Gen1 x4, one tester — direction, not gospel):
Qwen3.6-27B-AWQ-INT4 ~58 tok/s decode / ~2000 tok/s prefill (vLLM);
llama.cpp qwen 27B Q4_K_M ~888 tok/s pp512 / ~37 tok/s tg128.

**Known costs:** the x4 Gen1 link is the bottleneck for weight streaming and
multi-card tensor parallelism (TP is a dead end at this link; pipeline
parallelism is the multi-card strategy). No ECC. No NVLink/P2P.

---

## 2. The unlock: what it is, what it isn't

Tool: [`amoghmunikote/cmpunlocker`](https://github.com/amoghmunikote/cmpunlocker)
(reference wiki: [`Consensus-Protocol/cmp170hx`](https://github.com/Consensus-Protocol/cmp170hx)).
The community runbook [`abobasixseven/unlock-cmp-170hx`](https://github.com/abobasixseven/unlock-cmp-170hx)
wraps this tool; see §2.5 for where it is stale.

**Pinned for this project: master rev `88e39ce67488796b2c6c716fe8f9b4e6e943a55e`
(2026-09-13)**, `sha256-52lIswLRWXwEskxkYaDK55w0giMzMReLgqX3RmQRU/4=`.

### 2.1 What the tool does

`driver/build.sh` downloads `open-gpu-kernel-modules-<ver>` from the NVIDIA
GitHub tag, applies **eleven patches** in fixed order, then (only for older
patch sets without the runtime-geometry markers — not the case at the pinned
rev) rewrites CFG1/LMR/FB_BYTES at build time. It runs `make modules` against
the *running* kernel's headers, installs the five `nvidia*.ko` into
`/lib/modules/$(uname -r)/updates/cmpunlocker/`, runs `depmod -a`, rebuilds
the initramfs, and hot-reloads. `install.sh` wraps all of that plus:

- IOMMU cmdline setup (`intel_iommu=on iommu=pt` via GRUB or
  `/etc/kernel/cmdline`) — **not applicable on NixOS**; we set
  `boot.kernelParams` in the flake instead,
- the early-boot PCIe Gen2 retrain service (§2.3),
- optional VFIO passthrough arming (`--no-passthrough` skips it).

### 2.2 The eleven patches (order = `driver/build.sh` `PATCH_ORDER`)

| # | Patch | What it does |
| --- | --- | --- |
| 0001 | `sec2-postbl-plm-ss-cfg` | **Core.** Weakens the WPR2 check; opens **4 PLM registers** via Booter_Load *before* GSP-RM boots (FEAT/FBPA/WPR/WPR_CFG); host-writes SS0/SS1 (SM throttle off) and CFG1/LMR (memory geometry); **geometry is chosen at runtime by PCI ID** (0x20C2 → 64 GB, 0x2082 → 40 GB); patches `fb_length` in the GSP static info; rebuilds the stock signature so GSP-RM boots normally |
| 0002 | `booter-verify` | `SEC2_DEBUG` nv_printf trail (PLM/SS0/SS1/CFG1/LMR before/after) |
| 0003 | `late-pma` | Registers the [8 GB, 64 GB] FB region as public; disables compression for the 170HX |
| 0004 | `bar0-pramin-clamp` | Clamps BAR0/PRAMIN offsets to stock 8 GB when FB > 8 GB |
| 0005 | `ce-scrub-workarounds` | PTE-kind + VAS fixes for CE scrub on the high region |
| 0006 | `persistent-sw-state` | `NV_FLAG_PERSISTENT_SW_STATE` for 0x20C2/0x2082 |
| 0007 | `pcie-gen2` | Gen2 register sequence pre-GSP: opens 22 PLM-protected regs (XP3G/XVE/OPTB/FEAT_OVR_ECC), clears `OPT_GEN23`, `CYA_0 DIS_G2`, sets `LINK_CONFIG_0 MAX_RATE=2`, `PRIV_MISC_1`, retrains; late re-apply after GSP boot |
| 0008 | `pcie-gen2-probe-retrain` | Gen2 retrain at probe time |
| 0009 | `name-string` | `nvidia-smi` reports "NVIDIA CMP 170HX" |
| 0010 | `bar1-resize-unlock` | **Resizes BAR1** (XVE regs + REBAR) to the unlocked size — the 64 GB BAR problem (§8 R5) is handled in-driver |
| 0011 | `cmp-sku-mask` | Reports `CMP_SKU_NO` to userspace so apps don't see the mining-card flag |

Because the geometry is runtime-per-PCI-ID at this rev, **one module build
serves both 8 GB and 10 GB cards**; `--profile` is a metadata label only.

### 2.3 PCIe Gen2 (built in now)

Gen1→Gen2 is part of the pinned tool: patch 0007 opens a Gen2 window ~8–14 s
after boot while GSP bootstraps; a userspace "hammer" service
(`tools/hammer.sh` + `systemd/gen2.service`) fires root-port retrains every
50 ms from `sysinit.target` until the link catches the window, then it stays
trained. Verified in the field on an AMD B650 host (8 GB and 10 GB cards).
Gen2 is the software ceiling (Gen3/4 are OTP-fuse locked). Some PCB
revisions have `OPT_GEN23`/`VSEC_DEVICE` hard-locked at the SEC2 level —
those stay Gen1 with no other harm.

### 2.4 Safety properties (unchanged from the wiki)

- The unlock writes **volatile registers only** (PLM masks, memory geometry
  CFG1/LMR, SM throttle registers) during GSP boot. No VBIOS flash, no
  fuses, no master kill fuse. All state reverts on power loss.
- Reverting = stock module + cold boot. **No permanent brick caused by the
  unlock has ever been confirmed.** (One unexplained wedged-card report
  exists; the documented reset ladder — FLR → SBR → cold boot with PSU off —
  has cleared everything else.)
- Requirements: Linux x86-64, root, **Secure Boot disabled** (unsigned
  modules — moot when the module is built and loaded by NixOS, but the T2
  must still allow unsigned modules), kernel headers for the running kernel,
  a **cold boot** (PSU off ≥ 60 s so WPR2 clears; a warm reboot is not
  equivalent) after the module changes.

### 2.5 `abobasixseven/unlock-cmp-170hx` — what to take from it

Three runbooks (RU/EN), no code. The core install/verify/rollback README is
written against the **6-patch, 610.43.03-only** era and is stale:

| | runbook | cmpunlocker @ `88e39ce` (pinned) |
| --- | --- | --- |
| Patches | 6 | 11 (Gen2, BAR1 resize, SKU mask, name string added) |
| Driver versions | 610.43.03/.02 only | 615.71.09, 610.57.04, 610.43.03, 610.43.02 |
| Geometry | build-time rewrite per `--profile` | runtime per PCI ID |
| Gen2 | bendy2 fork + separate studebaker8 service | built in (patches 0007/0008 + hammer service) |
| 64 GB BAR1 | unaddressed | patch 0010 |
| CI | none | `test_compile` / `test_patches` / `test_lint` |

Still useful from the repo: the **verification checklist** (SEC2_DEBUG lines,
register readbacks; `status=0xffff` on PLM lines is *normal* — the
`BooterLoad status` line must read `0x0`), the **cold-boot discipline**, and
the **`UNDERVOLT CMP 170HX.md`** runbook for `cachenetics/170tune`
(SM undervolt via `nvmlDeviceSetGpcClkVfOffset` + clock ceiling, gated by
hot full-VRAM sweeps + GEMM, persisted across reboots) — that one is
userspace and still accurate; it's Stage 4 material.

---

## 3. Comparison: the unlock vs. the nixpkgs nvidia-open driver

The driver being replaced is the nixpkgs **open** kernel module
(`hardware.nvidia.open = true` → `nvidia_x11.open` in
`boot.extraModulePackages`), built from `pkgs/os-specific/linux/nvidia-x11/`.

How the nixpkgs driver is assembled (verified at frozen rev `0ae2bc1419c3`):

- `generic.nix` (`mkDriver`) takes `version` + NVIDIA download hashes and
  produces one derivation with outputs:
  - `out` — userspace (libcuda, CUDA UMD),
  - `bin` — nvidia-smi, nvidia-settings, nvidia-powerd,
  - `firmware` — GSP firmware extracted from the `.run`,
  - `open` / `mod` — the **open** / closed kernel modules,
  - `persistenced` — nvidia-persistenced.
- `kernel-modules.nix` (the `open` output) fetches
  `NVIDIA/open-gpu-kernel-modules` at tag `<version>` (sha256 = `openSha256`),
  applies `patches` (rewritten `kernel/`→`kernel-open/`) **`++ patchesOpen`**,
  and builds `make modules` **against `kernel.dev`** (the kernel of the
  `nvidiaPackages` set — for `config.boot.kernelPackages.nvidiaPackages`,
  the pinned T2 6.18.44 kernel) with `SYSSRC`/`SYSOUT`/`MODLIB` make flags.
  Sandbox build, no host state touched.
- **`patchesOpen` is the nixpkgs hook for extra patches on the open module
  build.** The 11 cmpunlocker patches (already written against
  `kernel-open/` + `src/nvidia/`, i.e. the open tree) slot in there verbatim,
  applied by stdenv's default `patch -p1`.

The unlock is therefore a **drop-in replacement for the kernel-module half
only**. Everything else stays nixpkgs and stays in lockstep automatically
because it comes from the same derivation:

| Half | Stock nixpkgs driver | With the unlock |
| --- | --- | --- |
| `nvidia*.ko` (kernel modules) | stock open-gpu-kernel-modules | **same source + 11 cmpunlocker patches** (PLM-open pre-GSP, geometry, Gen2, BAR1, SKU mask) |
| `out` / `bin` userspace (libcuda, nvidia-smi, CUDA 13 UMD) | 610.57.04 | unchanged |
| `firmware` (GSP) | stock, extracted from `.run` | unchanged (the unlock deliberately does not touch firmware) |
| `persistenced` | 610.57.04 | unchanged |

Why feed the patches through `patchesOpen` instead of running
`install.sh`/`build.sh` on the machine:

1. **`/lib/modules/$(uname -r)` is a read-only store path on NixOS** — the
   tool's install step (write `updates/cmpunlocker/`, `depmod -a`, initramfs
   rebuild) cannot run as-is.
2. **Module-tree collisions are build errors, not coin flips.**
   `system.modulesTree` is `pkgs.aggregateModules [ kernel-modules ] ++
   boot.extraModulePackages`, and the `buildEnv` aggregator **dies** when two
   paths contain different files at the same location (unless one has a
   lower `meta.priority`). A machine-local `updates/cmpunlocker/` tree
   shadowing the store tree is exactly the fragile "which nvidia.ko does
   depmod load" failure the wiki documents. With `patchesOpen` there is only
   one `nvidia.ko` in existence — `nvidia_x11.open` *is* the unlocked module.
3. **Reproducibility + lifecycle.** The unlock becomes part of
   `nixos-rebuild`: it can't be silently dropped, it re-applies on a kernel
   bump (the module rebuilds against whatever `boot.kernelPackages` is), and
   rollback is `git revert` + rebuild + cold boot. The NVIDIA tarball and the
   patch set are both fetched with pinned hashes.

Version choice: **610.57.04**. It is the `new_feature` branch on *both* the
frozen (`0ae2bc1419c3`) and rolling (`d6524aaca2ff`) nixpkgs with identical
hashes, and it is in cmpunlocker's supported list. We pin it via `mkDriver`
with the hashes copied from nixpkgs `default.nix` rather than following the
`new_feature` branch attribute, so a future `nix flake update` (which moves
`new_feature` toward 615.x eventually) cannot silently change the driver
under the unlock.

---

## 4. Hardware prerequisites (physical / shopping list)

### 4.1 Confirm the SKU before anything else

```sh
lspci -nn | grep -iE '10de:20b0|10de:20c2|10de:2082'
```

`20c2` = 8 GB → 64 GB. `2082` = 10 GB → 40 GB. `20b0` = **never unlocks**.
Decide which card to buy accordingly (64 GB is the goal).

### 4.2 Power — the real constraint on a Mac Pro 7,1

The card takes its power over a single EPS 8-pin (via the included
2× PCIe-8-pin → EPS Y-adapter). **Never force a PCIe 8-pin cable into the
socket** — the keying differs, they only go together if forced, and 12 V/GND
are swapped on some pins; forcing it damages the card.

Budget check for donnager (Mac Pro 2019, Xeon W-32xx ~80 W):

| Item | Draw |
| --- | --- |
| 170HX at stock 250 W | 250 W |
| Vega II (passive, ~250 W TDP) | up to 250 W |
| CPU + platform + disk | ~130 W |
| **Total** | **~630 W** |

If donnager has the stock **600 W PSU** (likely — the Vega II was sold with
it), that is over budget under simultaneous full load. Options, in order of
preference:

1. **Upgrade to the 1450 W PSU** (Apple option part 820-01305). Note it
   supplies 12 V-2x6 (16-pin) cables, so we'd need a 16-pin → 2× 8-pin PCIe
   splitter for the Y-adapter. Also enables multi-card later.
2. **Stay on 600 W and power-limit the card** (`nvidia-smi -pl 200` or
   lower — the wiki measures only a small throughput cost). 200 W + idle
   Vega II fits; 250 W + loaded Vega II does not. Fine for single-card use.
   The Stage 4 undervolt (170tune) drops draw to ~120–135 W at ~0 %
   compute loss, which makes 600 W comfortable.
3. Physically remove the Vega II when running the 170HX (loses the Vulkan
   models and the POST/display-capable GPU — not recommended as steady state).

Also count the PSU's actual PCIe 8-pin (6+2) cables: the Y-adapter needs
**two** 6+2 feeds at full power (one leg is acceptable at ≤150 W).
Idle draw of the card is 27–46 W (a resident model adds ~12 W).

### 4.3 Cooling — the most likely way to kill the card

The card is passive; without forced air it runs to 90+ °C and cooks the HBM.
Measured options (wiki cooling page; targets ≤70 °C core / ≤75 °C HBM):

| Option | Evidence | Notes for the Mac Pro |
| --- | --- | --- |
| **Level1Techs A-series blower adapter** (printed, bolts to the card's screw holes) + 9733S 12 V blower | Best-evidenced: 64→36 °C idle, 80+→40–50 °C load (on an A100, same PCB) | Blower exhausts toward the case rear, matching the Mac Pro's airflow. Card becomes longer — check clearance in the chosen slot |
| 2× Arctic S4028-15K 40 mm on a 2-slot bracket | Never above 70 °C GPU / 76 °C hotspot at full 300 W | Loud at 15 kRPM; compact |
| San Ace B97 blower + fan controller | <65 °C at 250 W sustained | Needs a curve controller |
| **Water:** Bykski N-TESLA-A100-X-V2 (40 GB-family block — *not* the 80G block) + 360 mm rad | 30 °C idle / 45 °C after 30 min @180 W at minimum pump/fan speed | Only route to sub-50 °C; Mac Pro has room for a rad, but plumbing + leak risk in a server chassis. V2 (all-metal) revision only |

Avoid: the widely sold "A100 cooler" 3.24 W snail-fan adapter (measured
150–180 W max, not the advertised 300 W), single 40 mm fans (90 °C hotspot),
sleeve/push shrouds (blowback), friction-fit printed ducts (they fall off —
screw everything on), any shroud that blocks the EPS plug (test-fit with the
cable installed).

**Decision needed:** blower adapter (air) vs A100 water block. Air is the
lower-risk default; the Mac Pro's rear exhaust makes a blower sensible.

### 4.4 Slot choice and POST

- Mac Pro 2019: 8 PCIe 4.0 slots; slots 1–3 are x16, slots 4–8 are x4
  electrically. The card is x4-native (Gen1, Gen2 after unlock), so **any
  slot is electrically fine** — pick one with clearance for the cooler and a
  good rear exhaust path.
- Keep the Vega II installed (POST/display fallback; it's a headless box
  anyway).

### 4.5 Secure Boot

The patched modules are unsigned. Check current state:

```sh
mokutil --sb-state          # EFI view
# T2 view: T2 Setup Utility (Option at boot) — Secure Boot must be disabled
# (or most permissive) for unsigned modules.
```

donnager already boots a from-source T2-patched kernel, so Secure Boot is
likely already disabled — but **verify, don't assume**, and note it in the
design log if it had to be changed.

---

## 5. donnager flake / config changes

### 5.1 New file `hosts/donnager/nvidia.nix` (+ import in `default.nix`)

The derivation below **is** the unlock. Staging is done by uncommenting the
marked lines: Stage 1 ships the stock 610.57.04 open driver; Stage 2
uncomments `patchesOpen`; Stage 3 uncomments the Gen2 parts.

```nix
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
    sha256_64bit       = "sha256-suk1xmuDuwDAyFe8jg/VLekoa0DJzB7sKafOfrEW0=";
    openSha256         = "sha256-rQHOOOY4KL92Ww3KDwh+j4eGU7oNAH8LutZC5wmFnPo=";
    settingsSha256     = "sha256-ZEMo8I8Zc2Tq6RVDNYpAH+f094dUaZiBqO+5f6lIjRI=";
    persistencedSha256 = "sha256-aXmD2VY1RLlgAnlHhOUMWzvMyhI6JTClcFLm4imF/mA=";

    # STAGE 2 — the unlock. Stock driver while commented out.
    # patchesOpen = cmpPatches;
  };
in
{
  hardware.nvidia.package = nvidia;
  hardware.nvidia.open = true;               # GA100: open modules only
  hardware.nvidia.modesetting.enable = true; # headless, no X/Wayland
  services.nvidia-persistenced.enable = true;

  # 64 GB BAR1 after unlock needs large MMIO allocation; also keeps the
  # door open for VFIO passthrough (cmpunlocker supports it).
  boot.kernelParams = [ "intel_iommu=on" "iommu=pt" ];

  # STAGE 3 (GEN2) — registry dwords; what cmpunlocker's install.sh writes
  # to /etc/modprobe.d/cmp-pcie-gen2.conf. Inert while the link is Gen1.
  # hardware.nvidia.moduleParams.nvidia = {
  #   NVreg_RegistryDwords = "RmForceEnableGen2=1;RMPcieLinkSpeed=0x1";
  # };

  # Power limit + persistence mode. Final value from the Stage 2 thermal
  # soak: 200 W on the 600 W PSU, 250 W after a 1450 W upgrade.
  systemd.services.nvidia-powerlimit = {
    description = "CMP170HX power limit + persistence mode";
    wantedBy = [ "multi-user.target" ];
    after = [ "nvidia-persistenced.service" ];
    serviceConfig = { Type = "oneshot"; User = "root"; };
    script = ''
      ${nvidia.bin}/bin/nvidia-smi -pm 1
      ${nvidia.bin}/bin/nvidia-smi -pl 200
    '';
  };

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
```

Notes:

- `config.boot.kernelPackages` is the frozen T2 kernel set (`flake.nix`
  forces `t2KernelPackages`), so the NVIDIA kernel module builds against
  6.18.44 automatically. **Whether 610.57.04 open modules build against
  6.18.44 is the one real unknown in Stage 1** — the first
  `nixos-rebuild switch` answers it. (The stock driver at that version
  builds first, without the patches, isolating kernel-compat from
  patch-compat.)
- `hardware.nvidia` blacklists `nouveau` automatically; `gpu.nix`
  (Vega II) is untouched — RADV/Vulkan and the NVIDIA stack coexist.
- The NixOS nvidia module takes care of: GSP firmware
  (`hardware.firmware = nvidia_x11.firmware`, `gsp.enable` defaults to true
  for open ≥555), `nvidia-smi` on the profile (`nvidia_x11.bin`),
  `boot.kernelModules`, and `/dev/nvidia*` permissions via the `video` group.
- **`flake.nix` itself is unchanged** — no new inputs.

### 5.2 `hosts/donnager/llama-swap.nix`

- Check nixpkgs `llama-cpp` CUDA support. If the packaged build is
  Vulkan/CPU-only, add an overlay:

  ```nix
  llamaCppCuda = prev.llama-cpp.override {
    withCuda = true;                       # or cmakeFlags, depending on the
  };                                       # package's args on our nixpkgs rev
  ```

  with `-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=80` and CUDA 13 from
  `pkgs.cudaPackages` (driver 610 = CUDA 13.x UMD). Verify with
  `llama-bench --list-devices` that the 170HX shows up as a CUDA device.
- Add a second macro (`llama-server-cuda`) and model entries targeting the
  64 GB card (e.g. a 70B-class Q4, or the current 27B at Q8 with a big
  context). Keep the existing Vulkan models on the Vega II untouched.
- Note: llama-swap spawns servers as the `llama` user — confirm the NVIDIA
  devices are accessible (`/dev/nvidia*` permissions — the nixos module
  handles this via the `video` group).

### 5.3 Other touch points

- `hosts/donnager/default.nix`: import `./nvidia.nix`; add `nvtop` (nvidia
  flavour) to system packages.
- `hosts/donnager/t2fanrd.nix`: verify/adjust the fan curve for GPU-load
  heat (case fans are the only system cooling).
- `README.md`: hardware section (second GPU, power, cooler), services table
  unchanged, secrets unchanged.
- `secrets/`: no changes.
- `flake.lock`: no changes (no new inputs).

---

## 6. Testing plan (staged, each stage gates the next)

### Stage 0 — bench / pre-flight (before the card touches the Mac Pro)

1. `lspci` SKU confirmation (§4.1).
2. Stock-driver smoke test (spare Linux box, or directly after Stage 1):
   `nvidia-smi` sees the card, reports 8192/10240 MiB, CC 8.0, no Xids.
   This is the "it's a live card" baseline.
3. Cooler fit: with the power cable installed, verify the shroud/adapter
   doesn't block the EPS plug; verify card length fits the chosen slot.
4. Thermal pre-check *before unlock*: 10 min load at `nvidia-smi -pl 150`
   with the chosen cooler; confirm <70/75 °C. If cooling fails here, stop —
   no point unlocking a card you can't keep cool.

### Stage 1 — NixOS NVIDIA driver foundation (no unlock yet)

Commit §5.1 as-is (no `patchesOpen`, no Gen2), `nixos-rebuild switch`, then:

1. **Build succeeds** — 610.57.04 open modules against T2 6.18.44. The one
   real unknown in the whole plan; if it fails, stop the line.
2. `cat /proc/driver/nvidia/version` → `NVIDIA UNIX Open Kernel Module for
   x86_64  610.57.04`.
3. `nvidia-smi` → card visible, 8192/10240 MiB, CC 8.0, `Fan Speed: N/A`
   expected, no Xids.
4. IOMMU in effect: `dmesg | grep -i -e DMAR -e IOMMU` (needed later for the
   64 GB BAR; the BAR itself is checked at Stage 2).
5. Persistence: `nvidia-persistenced` running; `nvidia-smi -pl 200` applied
   by the oneshot and survives a reboot.
6. Vega II regression: `vulkaninfo` + a short llama-swap Vulkan model load
   still works — the two stacks must coexist.
7. `nixos-rebuild switch` again (idempotence) + reboot — driver must come
   back at 610.57.04, not whatever rolling nixpkgs would pick.

### Stage 2 — the unlock

Uncomment `patchesOpen = cmpPatches;`, `nixos-rebuild switch` (the module
rebuilds with the 11 patches), then:

1. **Cold boot:** power off at the strip, ≥60 s, power on. (A plain reboot
   is not a cold cycle — WPR2 must clear.)
2. Verify (all of):
   - `nvidia-smi` → **65536 MiB** (8 GB card) / 40960 MiB (10 GB card),
     name "NVIDIA CMP 170HX" (patch 0009).
   - `sudo dmesg | grep SEC2_DEBUG` → full healthy trail (PLM readbacks,
     `POST-WRITE` lines, `BooterLoad status=0x0`). `status=0xffff` on PLM
     lines is *normal*; the BooterLoad line must read zero.
     `PLM[0] WPR_CFG` reads `0xfffff0ff` by design.
   - `modprobe -n -v nvidia | head -1` → resolves into the store tree of
     *our* derivation (there is exactly one `nvidia.ko`; shadowing is not
     possible).
   - **BAR1 is now 64 GB:** `lspci -vvv -s <bdf>` + `dmesg | grep -i bar` —
     patch 0010 resizes it in-driver, but the Mac Pro's MMIO map absorbing a
     64 GB BAR is still unverified; watch for "can't allocate" /
     resource-shortage errors. If allocation fails, stop the line.
3. **Memory stress** (is the VRAM real, not an aliased fold — Xid 31 risk):
   - Full-VRAM allocation test (>60 GB allocated) with a CUDA/clpeak-style
     bandwidth tool, and `tools/hammer.sh` from the cmpunlocker checkout.
   - 1 h+ sustained LLM load in the top ~90 % of VRAM; watch
     `nvidia-smi -q -d ECC,XID` and `dmesg` for Xid 31
     (`FAULT_INFO_TYPE_REGION_VIOLATION` = allocated past the usable window —
     back off the allocation headroom and record the safe ceiling).
4. **Thermal soak:** 1 h sustained load at the intended power limit with the
   final cooler; record core/HBM/hotspot curves. Gate: ≤70/75 °C sustained,
   else re-power-limit or re-cool.
5. **Reboot ×2:** unlock must survive. Check that the patched module is the
   one loaded after reboot (`modprobe -n -v nvidia` store path + fresh
   `SEC2_DEBUG` lines in `dmesg`).
6. **Rollback rehearsal (do it once, deliberately):** comment out
   `patchesOpen`, `nixos-rebuild switch`, cold boot → card back to
   8192 MiB and healthy → re-enable, rebuild, cold boot. Proves the escape
   hatch works on *this* machine before we depend on it.

### Stage 3 — Gen2 + workload integration

1. **Gen2:** uncomment the two GEN2 blocks (§5.1), `nixos-rebuild switch`,
   cold boot. Verify:
   - `/var/log/gen2.log` → `SUCCESS Gen2 at iteration N` (field behaviour:
     ~iteration 30). `gave up after 600 attempts` = window missed or PCB
     revision with SEC2-locked `OPT_GEN23` (then: stay Gen1, no harm, stop
     the Gen2 line).
   - `cat /sys/bus/pci/devices/<bdf>/current_link_speed` → `5.0 GT/s`
     (authoritative; `nvidia-smi` may cache the probe-time value).
   - H2D/D2H bandwidth test → ~1.5–1.6 GB/s (vs ~0.8 Gen1).
2. **llama.cpp (CUDA):** build/obtain an SM80 build
   (`-DCMAKE_CUDA_ARCHITECTURES=80`, CUDA 13 — prebuilt ggml libs link
   `libcudart.so.13`; on a CUDA 12 host they fail *silently* by falling back
   to CPU and OOMing). Run `llama-bench` pp512/tg128 on a 27B-class Q4 model;
   compare against the Vega II baseline and the wiki reference numbers
   (~888 / ~37 tok/s). Expect several hundred tok/s prefill.
3. **llama-swap:** add the CUDA `llama-server` instance for the 170HX
   (§5.2) with 64 GB-class models — the whole point, models that don't fit
   the Vega II's 16 GB.
4. **open-webui:** confirm the new models route correctly.
5. Optional eval (decision, §8 Q4): vLLM vs llama.cpp as primary 170HX
   backend (wiki: vLLM ~1.8× on one card, only stack that runs big MoE
   models well; llama.cpp is simpler and already in the stack).

### Stage 4 — undervolt, soak and handover

1. **Undervolt (optional, per `abobasixseven` `UNDERVOLT CMP 170HX.md`):**
   `cachenetics/170tune` — `nvmlDeviceSetGpcClkVfOffset` + clock ceiling,
   start at +250/1350 (~34 % power savings at ~0 % loss), every point gated
   by 4× hot full-VRAM sweeps + GEMM, persisted with `170tune persist`.
   Note: the tool installs to `/usr/local` (machine-local state, acceptable
   here or skip entirely); it requires the unlocked card (VF range opens
   post-unlock). Synergy: at ~120–135 W draw the 600 W PSU stops being a
   constraint.
2. **24–48 h mixed soak:** models cycling in/out (llama-swap TTL), idle
   periods; watch PSU headroom and t2fanrd fan behaviour under GPU load
   (case fans are the only system cooling — verify the curve actually ramps,
   since blower exhaust + HBM/VRM heat still land in the chassis).
3. **Monitoring:** add `nvtopPackages.nvidia` (or `nvtop`) to
   `environment.systemPackages` next to the existing `nvtopPackages.amd`.
4. **Handover:** update `README.md` (hardware + services), and the LocalGPT
   design log with the final config (power limit, undervolt point, cooler,
   safe VRAM ceiling, driver pin, unlock rev, Gen2 status).

---

## 7. Rollback and failure modes

| Failure | Recovery |
| --- | --- |
| Unlock didn't take (still 8192 MiB) | Cold boot; if persistent, revert `patchesOpen` + rebuild + cold boot, then re-apply |
| GSP won't boot / "No devices were found" | Cold power cycle (PSU off ≥60 s) |
| Card wedged, `nvidia-smi` hangs, Xid 119/154/31 | Reset ladder: FLR → SBR → cold boot |
| Host CUDA runtime wedged (`cuInit` 999) | Reboot |
| Gen2 window missed / stuck Gen1 | Check `/var/log/gen2.log`; another cold boot; if `FAILED to set OPT_GEN23` in dmesg → PCB revision with SEC2-locked regs, accept Gen1 |
| NixOS config broken | `nixos-rebuild --rollback` — the driver pin means the unlock never depends on the rolling default, and there is no machine-local module state to get out of sync |
| Card bricked? | Not by the unlock (volatile registers only, fully reverted by module revert + power cycle). By physics: bad cable, no cooling, bad VBIOS flash — all avoided by §4 |

---

## 8. Risks and open questions

### Risks

- **R1 — Power.** 600 W PSU + 250 W card + Vega II is over budget at
  simultaneous full load. Mitigation: §4.2 decision before first full-load
  test; Stage 4 undervolt removes most of the pressure.
- **R2 — Cooling.** Passive card in a chassis designed for blower GPUs.
  Mitigation: Stage 0/2 thermal gates before any unlock or long soak.
- **R3 — Rolling nixpkgs (resolved).** The driver version and all four
  NVIDIA tarball hashes are pinned in `nvidia.nix` (§5.1), independent of
  the `new_feature` branch; nixpkgs drift only affects build machinery.
  Bumping the driver = deliberate edit of version + hashes + cmpunlocker
  rev together.
- **R4 — Supply chain (mitigated).** The whole unlock is one community's
  work. Mitigation: cmpunlocker pinned by rev + hash; the NVIDIA tarball
  fetched with `openSha256` verification inside the Nix build; the 11
  patches are readable and small (largest ~19 KB); patch application is
  reproducible and happens in the sandbox, not on the machine.
- **R5 — 64 GB BAR on the Mac Pro MMIO map (mitigated, still a gate).**
  Patch 0010 resizes BAR1 in-driver (XVE + REBAR), but a 64 GB MMIO
  allocation on this specific platform is unverified. `intel_iommu=on` is
  in place; Stage 2.2 is the stop-the-line gate.
- **R6 — Xid 31** (allocation past the usable window). Mitigation: Stage 2.3
  stress, record the safe VRAM ceiling, configure llama-swap contexts below
  it.
- **R7 — Patch set × 610.57.04 × T2 6.18.44.** Upstream CI compiles the
  patches against its supported driver versions, but the T2 6.18.44 kernel
  combination is unverified. Stage 1 (stock build, no patches) isolates
  kernel compatibility; Stage 2 isolates patch application.
- **R8 — Gen2 window timing on T2.** Module-load timing differs from the
  AMD reference host; if the hammer's 30 s window misses the GSP-bootstrap
  window, the link stays Gen1 (no harm). Re-arm with another cold boot;
  worst case accept Gen1 (single-card serving is fine at 0.8 GB/s).

### Open questions (decide in this order)

1. **SKU:** buy an 8 GB card (→64 GB) — assumed yes; confirm budget.
2. **PSU:** 1450 W upgrade vs 600 W + power limit (+ Stage 4 undervolt).
   Drives the power-limit value in §5.1 and whether multi-card is ever on
   the table.
3. **Cooler:** blower adapter (default) vs A100 water block.
4. **Backend:** llama.cpp (already in stack) vs vLLM (faster, heavier
   dependency) as the 170HX's primary server.
5. **Undervolt:** adopt `170tune` (machine-local install, or package it) or
   skip and rely on the power limit.
6. **Gen2:** enable in Stage 3 (recommended — 2× weight-stream bandwidth) —
   or defer; single-card serving works at Gen1.

### Resolved during this rewrite (2026-09-18)

- **nixpkgs 610 availability:** 610.57.04 exists as `new_feature` on both
  the frozen and rolling nixpkgs; pinned via `mkDriver` (§3, §5.1).
- **Unlock packaging:** `patchesOpen` derivation is the only viable path on
  NixOS — the old Option A (manual `install.sh` into `/lib/modules`) is
  rejected: the modules dir is a read-only store path, and a shadowing
  `updates/cmpunlocker/` tree is the fragile depmod-resolution failure mode.
- **Gen2:** built into cmpunlocker master (patches 0007/0008 + hammer
  service) — no bendy2 fork or studebaker8 repo needed.
- **64 GB BAR1:** handled in-driver by patch 0010 (was an open platform
  question).

---

## 9. Sources

- [`amoghmunikote/cmpunlocker`](https://github.com/amoghmunikote/cmpunlocker)
  — the unlock tool. Pinned: master `88e39ce67488796b2c6c716fe8f9b4e6e943a55e`
  (2026-09-13), `sha256-52lIswLRWXwEskxkYaDK55w0giMzMReLgqX3RmQRU/4=`.
  Read: `install.sh`, `driver/build.sh`, `driver/patches/*` (11),
  `common/constants.yaml`, `tools/hammer.sh`, `systemd/gen2.service`,
  `verify.sh`.
- [`abobasixseven/unlock-cmp-170hx`](https://github.com/abobasixseven/unlock-cmp-170hx)
  — community runbooks (README, `cmp170_gen2_patch.md`,
  `UNDERVOLT CMP 170HX.md`). Core install doc stale vs. the pinned tool
  (§2.5); verification checklist + cold-boot discipline + undervolt runbook
  still used.
- [`Consensus-Protocol/cmp170hx`](https://github.com/Consensus-Protocol/cmp170hx)
  — community wiki (55 pages): quick-start, risks, driver-versions,
  power-and-psu, cooling, llm-inference, multi-gpu, recovery. Treated as the
  primary hardware reference; it marks single-source claims as such.
- nixpkgs `0ae2bc1419c3` (frozen) and `d6524aaca2ff` (rolling):
  `pkgs/os-specific/linux/nvidia-x11/{default,generic,kernel-modules,persistenced}.nix`,
  `pkgs/os-specific/linux/kmod/aggregator.nix`,
  `pkgs/build-support/buildenv/builder.pl`,
  `nixos/modules/hardware/video/nvidia.nix`,
  `nixos/modules/system/boot/kernel.nix`.
- NVIDIA 610 data-center driver release notes (610.43.03/610.43.02/610.57.04,
  CUDA 13.x).
- donnager repo: `flake.nix`, `hosts/donnager/{default,gpu,llama-swap,t2fanrd}.nix`.
