# Running Strata (Qwen3.8-Flash-Next) on donnager — work plan

Status: **planning**. Nothing in this doc has been executed yet.
Research current as of 2026-10-29 against Strata `main` at `46c152a`
(2026-10-28) and the sm_80 tuning data from issue #3712 / PR #3779.
Companion to `docs/cmp170hx.md` (the card it runs on); assumes that plan's
stages are done: card installed, unlocked to 64 GB, Gen2 x4 trained.

---

## 1. What Strata is, and what "QFN" is

[Strata](https://github.com/Niko1221/Strata) is an inference engine with a
one-click installer (`setup.sh`/`setup.py`): it sets up a private Python
venv, obtains or compiles the engine, downloads a pinned model, prepares it,
and serves an OpenAI- and Anthropic-compatible API (default
`127.0.0.1:8080`).

The model is **QFN = Qwen3.8-Flash-Next**: a 125B-total / 6B-active MoE
(512 routed experts) with DeltaNet (GDN) hybrid layers and a 262,144-token
native context. Two components beyond the experts matter for the memory
layout:

- a **51B-entry n-gram (PLE) table** at IQ4_NL (~29 GB), kept out of the
  quant search; it lives in RAM/SSD, not VRAM, and ships as the second
  GGUF shard (`--ple-gguf`). The `STRATA_PLE_*` switches are about it.
- a **4B MTP draft head** (~5 GB) fetched from the original Qwen
  checkpoint, for speculative decoding.

Model packs come from pinned Hugging Face commits with SHA-256 checks:
`Q2_0 | IQ2_XS | IQ3_XXS | IQ3_S`. The expert quant decides what sits in
VRAM — ~36 GB at IQ2_XS, ~47 GB at IQ3_XXS — while the PLE table stays
~29 GB either way.

Why IQ2_XS on this box: the ~36 GB expert pack fits entirely in the unlocked
64 GB of HBM2e — near-100% expert hit rate. That is exactly the condition
under which donnager's weak points (AVX2-only Xeon, Gen2 x4 link) stop
mattering: steady-state decode and prefill never touch the host link. The
link only matters for cold model load and conversation KV park/restore
(§5, PR 4). Q2_0 is the speed fallback if IQ2_XS misbehaves.

The GDN layers matter for the env-var staging below: several of the sm_80
switches exist specifically for the DeltaNet recurrence.

## 2. What the flake provides (the runbook's open question, answered)

`nix flake show github:Niko1221/Strata` exposes exactly one output:

```
devShells.x86_64-linux.default
```

No `packages`, no `apps`. The devShell is the build environment:

- `python3`, **CUDA 13.0** (`pkgs.cudaPackages_13_0` — the flake comment
  pins it deliberately: the ready-made engine is built with 13.0.88, and
  13.2.x miscompiles for sm_120), `cmake`, `ninja`
- `shellHook` sets `CUDA_HOME`/`CUDA_PATH`/`CUDAHOSTCXX` and fixes the
  classic NixOS pip-wheel problem:
  `LD_LIBRARY_PATH=/run/opengl-driver/lib` (libcuda) + libstdc++ + zlib

So the flake path is: **build inside the devShell, install the result,
manage the service in NixOS**. There is no package to consume, and the
"manual nix-shell build" last resort collapses into the same step — the
devShell *is* the shell.

The apt gotcha is handled upstream. `setup.sh` has an explicit
`ID=nixos` branch: on NixOS it creates the venv with **uv** (managed
Python 3.12) when uv is present, because Nix's Python cannot dlopen pip
wheels' libraries. Its own comment says: "On NixOS, add `uv` to
`environment.systemPackages`." Inside the devShell the stock venv path also
works (the `LD_LIBRARY_PATH` fix above), but uv is the documented route.

## 3. Why this card compiles instead of downloading

`setup.py` ships ready-made engine builds **only for RTX 20/30/40/50 cards**
(sm_75/86/89/120). GA100/sm_80 is not in that set, so the installer falls
through to "install the missing build tools and compile the engine for your
GPU" — which is what the devShell exists for. Expect a long nvcc run.

Consequence: the Strata team does not own sm_80 hardware, and the only
sm_80 tuning data that exists was measured by one contributor on a
CMP 170HX (issue #3712) — the same card as ours. The stage-1/stage-2 A/B
on donnager (§5–§6) is how we find out what is actually true on this box,
not just tidiness.

## 4. Install plan

### 4.1 Pre-flight

1. **Disk:** ≥ ~70 GB *additional* free on the NVMe — IQ2_XS pack + ~5 GB
   MTP draft + venv (the nvidia pip wheels are multi-GB) + build
   artifacts. On top of what is already there, including
   `/var/lib/llama/models/Qwen3.8flash` (llama-swap's UD-Q4_K_XL, ~80 GB).
2. **VRAM:** `nvidia-smi` → 65536 MiB, name "NVIDIA CMP 170HX" (unlocked).
   A card reporting 8192 MiB voids the resident-experts premise; stop.
3. **Link:** `cat /sys/bus/pci/devices/<bdf>/current_link_speed` →
   `5.0 GT/s` (Gen2). If it is Gen1, the slow-link conversation-cache
   switches matter more, not less — note it, don't block on it.
4. **RAM for the PLE table:** the ~29 GB n-gram table lives in RAM/SSD.
   With 71–80 GB of 96 GB committed, ~16–25 GB is free — the table does
   not fit resident, so it must be SSD/page-cache-backed. Re-check free
   RAM after the build and watch page-cache behaviour during the bench
   (§6.4). The single-card reference ran this on a 32 GB box (§7), so it
   is known to work — but ours has less headroom. Most likely silent
   killer on this box.

### 4.2 One-time build (on donnager)

```sh
git clone https://github.com/Niko1221/Strata /var/lib/strata/src
cd /var/lib/strata/src
nix develop        # the repo's own flake: CUDA 13.0 + cmake + ninja + python3
./setup.sh --yes --family qwen --model IQ2_XS --context 32768 --vision no --port 8081
```

What that does (each step is idempotent — re-running only does what is
missing):

1. venv (uv on NixOS) + Python packages (numpy, jinja2, nvidia CUDA libs)
2. **compiles the engine for sm_80** (no ready-made build; §3)
3. downloads the model from its pinned HF revision (resumable, SHA-256
   checked) + the MTP draft layer
4. prepares the model for Strata
5. writes `run-<model>.sh` and starts the server on port 8081

Everything the install writes lands in the checkout itself
(`setup.py`'s `home()` is the repo root) — so `/var/lib/strata/src` is the
payload the service points at. `--context 32768` keeps the KV cache small
(the bench's longest prompt is 32K; the model's trained context is 262144).

Note on the existing model: `/var/lib/llama/models/Qwen3.8flash` already
holds llama-swap's Qwen3.8-Flash-Next (unsloth UD-Q4_K_XL, 4 shards,
mmproj, MTP). Strata's `setup.py` expects its own pinned GSQ-RCO packs —
different quant, two-shard native+PLE layout. `--gguf-dir` exists for
reusing GGUFs, but compatibility with the unsloth layout is unverified.
Default plan: let setup.py download its own pack under `/var/lib/strata`;
the llama-swap folder stays untouched, and disk is budgeted for both.

After the first successful run: **inspect `run-<model>.sh`** to see exactly
what it execs (venv python + serve entrypoint, env it sets) — that is the
`ExecStart` for §4.3.

### 4.3 NixOS module `hosts/donnager/strata.nix`

The module is enable-gated (house pattern from `modules/mcp-servers`):
`services.strata.enable`, default `false`, so committing it is a no-op
until the out-of-tree build is verified by hand. The actual file is
`hosts/donnager/strata.nix`; the shape:

```nix
{ config, pkgs, lib, ... }:
let cfg = config.services.strata; in
{
  options.services.strata.enable =
    lib.mkEnableOption "the Strata inference engine (Qwen3.8-Flash-Next, port 8081)";

  config = lib.mkIf cfg.enable {
    systemd.services.strata = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        User = "strata"; Group = "strata";
        SupplementaryGroups = [ "video" "render" ];
        WorkingDirectory = "/var/lib/strata/src";
        # TODO(verify after the 4.2 build): point at what the generated
        # run-<model>.sh execs:
        ExecStart = "...";
        Environment = [
          # Stage 1 (bit-exact, PR #3779 set): GRAPH_PRIO, MMVQ_IL_PF,
          # MMVQ_IL_SM80, CKPT_ASYNC, PARK_ASYNC, CKPT_GATHER — plus the
          # runbook's N values (CKPT_VRAM_SLOTS / CKPT_POOL /
          # PARK_VRAM_MIB) and the AVX2 CPU switch, still to fill in.
          # Stage 2 (PF_FUSED_F16/WS, GDN_TC): commented out until the
          # stage-1 baseline is recorded.
        ];
        Restart = "on-failure"; RestartSec = 5;
        # MemoryMax: TBD per the runbook's RAM guidance.
      };
    };
    users.users.strata = { isSystemUser = true; group = "strata"; };
    users.groups.strata = { };
  };
}
```

Plus the import in `hosts/donnager/default.nix`. No new flake inputs
(the build happens out-of-tree in `/var/lib/strata`; only the service unit
is Nix-managed), and no firewall change: 8081 stays on 127.0.0.1 and
Open WebUI (same box, port 3000) gets a second provider at
`http://127.0.0.1:8081/v1`. llama-swap stays on 9292 untouched.

## 5. Env-var staging and expected effects

Two stages, deliberately separate so any gain is attributable. All numbers
below are the contributor's CMP 170HX measurements (issue #3712) — same
card, different host; treat as direction until §6 confirms them here.

**Stage 1 — bit-exact switches (the PR #3779 set).** Graph priority,
interleaved matvec, the three slow-link conversation-cache fixes built for
a Gen2 x4 link, plus the AVX2 CPU switch.

| Switch | Effect (contributor's card) |
| --- | --- |
| `STRATA_MMVQ_IL_SM80=0` (restore shared table) | decode +2.7..3.2 % |
| `STRATA_GRAPH_PRIO=1` | decode +1.8 % |
| `STRATA_MMVQ_IL_PF=1` (Q6_K hoisted-load) | decode +1.4 % |
| `STRATA_CKPT_ASYNC=1` + `STRATA_CKPT_VRAM_SLOTS=N` | checkpoint 71.4 → 0.9 ms; restore 114-126 → 28-47 ms |
| `STRATA_PARK_ASYNC=1` + `STRATA_CKPT_POOL=N` + `STRATA_CKPT_GATHER=1` | park @3.3K 212-217 → 21.5-40.1 ms |
| `STRATA_PARK_VRAM_MIB=N` | later restores 6.5-12.6 ms |
| AVX2 CPU switch (name from runbook) | keeps CPU code on the AVX2 path (no AVX-512 on the Xeon W) |

Overall on that card: decode 106.6 → 129.4 tok/s (1.20×); conversation
park/restore 5-10× faster.

**Stage 2 — prompt-path tensor-core switches.** Only after the stage-1
baseline is recorded.

| Switch | Effect (contributor's card) |
| --- | --- |
| `STRATA_PF_FUSED_F16=1` / `STRATA_PF_FUSED_WS=1` (f16 mma fused experts) | prompts +2..6 %; **not bit-exact** (1 of 11 greedy answers changed) |
| `STRATA_GDN_TC=1` (DeltaNet recurrence as chunked tensor-core scan) | recurrence 105 → 34 ms @3.3K, 1705 → 547 ms @52K; prompts +6.6..7.6 % |

Overall prefill on that card, ~3K-word prompt: 2,071 → 4,136 tok/s (2.0×)
across both stages.

## 6. Bench: `strata_bench.py` and what it does not measure

The A/B script (stdlib-only, in the uploads folder) points at any
OpenAI-compatible endpoint, discovers the model via `/models`, warms up,
then runs 2 repeats at ~1K/4K/32K prompts (256 output tokens, temp 0) and
prints TTFT + decode tok/s. It works unchanged against both Strata (8081)
and llama-swap (9292).

Gaps for *this* A/B, in order of importance:

1. **Conversation switching is never exercised.** Every run is a fresh
   conversation, so the entire PR-4 family — the biggest user-visible win,
   and the one built for our link — is invisible to the script. Add a
   switch loop: prime two long conversations, alternate between them,
   measure TTFT on the return visits. Without the fixes, parking a 32K KV
   over Gen2 x4 is seconds; with them, tens of ms.
2. **Best-of-2 cannot attribute 2-6 % deltas.** Use 3 repeats and report
   median + spread, not just best.
3. **Log the completion text (or a hash) per run.** Stage 1 is claimed
   bit-exact; stage 2 is not. Diffing outputs across stages verifies the
   claim on this hardware for free — the whole point of the A/B given the
   one-contributor caveat.
4. **Log `MemAvailable`/`SwapFree` from `/proc/meminfo` per run.** The
   script runs on donnager, so it can read them. With 71-80 GB of 96 GB
   committed and parked KV going to system RAM, a mid-run swap would kill
   the numbers silently and the script would print them anyway.

Sanity band for the results (contributor's card, everything on): prefill
~2K tok/s at stage 1, ~4K at stage 2; decode ~110-130 tok/s. Cross-check
against the single-card reference (§7): prefill 2,456 t/s @120K and
decode 97–145 t/s on *pre-tuning* v0.1.42 — a floor for us at 32K. If
stage 2 moves nothing, the tensor-core switches are not taking on this
card/host (driver/CUDA build on the unlocked card is the suspect) — that
is a finding in itself, not a failure of the trial.

## 7. Comparison: the single-card reference (Kanorin-chan)

[Kanorin-chan/cmp170hx-qwen38-flash-next](https://github.com/Kanorin-chan/cmp170hx-qwen38-flash-next)
is an unmaintained snapshot (2026-09/10) of the same model on one unlocked
CMP 170HX — the closest existing reference to our build. Strata v0.1.42
(**pre-#3779**, i.e. none of the tuning switches) plus a llama.cpp
b11401 lane, IQ3_XXS, 262K–524K context with YaRN, KV streamed to host
RAM, MTP and vision on.

| | Kanorin-chan | donnager (this plan) |
| --- | --- | --- |
| Link | Gen2 **x16**, 6.56 GB/s measured | Gen2 **x4**, ~1/4 of that |
| Host | i7-9700K, **32 GB** RAM, Ubuntu | Xeon W (AVX2), **96 GB** (71–80 committed) |
| Strata | v0.1.42, no tuning switches | main `46c152a` + stage-1/2 env |
| Quant | IQ3_XXS (47 GB shard + 29 GB PLE) | IQ2_XS per runbook (~36 GB experts) |
| Context | 262K–524K, YaRN, KV streamed to RAM | 32K — KV fits in VRAM, no streaming |
| MTP / vision | on / on | on (setup fetches it) / off |

His measured numbers (IQ3_XXS, single card): prefill 2,456 t/s @112–135K
falling to 1,488 @852K; decode 97 t/s @112–135K, ~145 t/s short-chat
(with MTP). llama.cpp lane: 1,031 prefill / 43 decode without MTP —
Strata's ~2.3× on this silicon is real. Because his Strata predates the
sm_80 tuning, these are a **floor** for us, not a target.

Lessons that affect this plan:

1. **The PLE table is the RAM story** — ~29 GB, fixed in every build,
   RAM/SSD-backed. He ran it on 32 GB total; we have ~16–25 GB *free*
   (§4.1.4). Verify placement and page-cache behaviour after the build.
2. **IQ3_XXS is a real alternative to IQ2_XS at our 32K target.** 47 GB
   shard + ~1 GB KV @32K + MTP ≈ 51–54 GB — fits without streaming.
   Quality per ISTA's own benchmarks: IQ3_XXS 92.57 vs IQ2_XS 89.16 task
   average (GPQA-D 91.4 vs 87.4, LCB 86.3 vs 83.4). IQ2_XS buys 25 GB of
   VRAM headroom we do not need at 32K. Q2_0 stays the speed fallback
   (ISTA: 3.4× prompt throughput, ~3.5 points less).
3. **Host-header quirk:** without an API key, Strata refuses unknown Host
   headers. Open WebUI talking to `127.0.0.1:8081` is fine; any
   Caddy-routed Host would need `--api-key` (setup.py has the flag) or
   `allowed_hosts` — and there is no auth either way, so prefer the key.
4. **Never offload experts to RAM.** His 6.56 GB/s link gave
   single-digit–15 t/s; our x4 link would be ~2–4 t/s.
5. **Do not force cuBLAS:** the 170HX's int8 tensor cores are throttled
   to ~50 TOPS, and the fp16/cuBLAS path measured 2× slower. The
   quantized MMQ path is the right one — which is also what the tuning
   switches optimize.
6. **CUDA 13.1 breaks the build** on his host (rsqrt header conflict,
   glibc 2.43). Our flake's 13.0 pin avoids it; do not "upgrade" the pin.
7. **Thermals:** his passive card sat at 80–86 °C with the SW thermal-
   throttle flag active; `nvidia-smi -pl 200` for sustained work. Our T2
   has active cooling (t2fanrd), but check temps during the 32K bench.
8. **Unlock v0.5** (+4 SMs, "ECC") was untested in the field at his
   snapshot date — his verdict: wait for reports. If our card is on
   v0.5, his numbers are not directly comparable (check which unlock
   revision we are on; `docs/cmp170hx.md` records it).
9. (llama.cpp lane only) `-b 4096 -ub 4096` was a ~48% prefill win over
   the 512 default — relevant if we ever touch the llama-swap Flash
   entry.

## 8. Rollback

Stop the service, drop the import + `strata.nix`, `nixos-rebuild switch`.
Optionally `rm -rf /var/lib/strata` (~70 GB). llama-swap on 9292 and the
Open WebUI provider list are the only other touch points; neither is
modified until Strata is up.

## 9. Open items

1. **The runbook note's exact env block** — the `N` values for
   `CKPT_VRAM_SLOTS` / `CKPT_POOL` / `PARK_VRAM_MIB`, the AVX2 CPU switch
   name, and whether the PR-2 slow-link prefill switches
   (`STRATA_PLE_COMPACT`, `STRATA_PLE_COPY_STREAM`, `STRATA_EMBED_VRAM`,
   `STRATA_DEQUANT_SIDE`) are in stage 1 or 2 here. `hosts/donnager/strata.nix`
   is filled from issue #3712 data and needs this.
2. **`ExecStart`** — read the generated `run-<model>.sh` after the §4.2
   build; the module's placeholder must be replaced before enabling.
3. **`MemoryMax` value** — per the runbook's RAM guidance (71-80 GB
   committed of 96).
4. **Disk** — confirm the NVMe has the ~70 GB *additional* headroom
   (§4.1.1) before the model download starts.
5. **Quant choice** — IQ2_XS (runbook default, VRAM headroom) vs
   IQ3_XXS (fits at 32K, +3.4 task-avg per ISTA, §7.2). Decide before
   the §4.2 download; both go through the same `setup.sh` flag.
6. **Host header / API key** — plain `127.0.0.1:8081` from Open WebUI
   works without a key; if the provider is ever addressed through Caddy
   with a non-localhost Host, set `--api-key` (setup.py flag) — §7.3.
7. **PLE table placement** — after the build: free RAM with the table
   mapped, and page-cache behaviour under the 32K bench (§4.1.4, §6.4).
8. **Unlock revision on our card** — v0.4 vs v0.5 (+4 SMs) affects
   comparability with both references (§7.8); `docs/cmp170hx.md` records
   it.

## 10. Sources

- [Niko1221/Strata](https://github.com/Niko1221/Strata) `main` @ `46c152a`
  (2026-10-28): `flake.nix` (devShell, CUDA 13.0 pin), `setup.sh` (NixOS/uv
  branch), `setup.py` (engine acquisition, model pins, flags).
- [Issue #3712](https://github.com/Niko1221/Strata/issues/3712) — sm_80
  tuning measured on a CMP 170HX: the five PRs, switch names, before/after
  numbers.
- [PR #3779](https://github.com/Niko1221/Strata/pull/3779) — the five
  features as commits (the stage-1 set).
- Runbook note "Strata trial on donnager" (local, not in this repo) — IQ2_XS
  choice, port 8081, RAM budget, staged env vars.
- [Kanorin-chan/cmp170hx-qwen38-flash-next](https://github.com/Kanorin-chan/cmp170hx-qwen38-flash-next)
  (2026-10-13, unmaintained snapshot) — single-card reference: model
  architecture (125B/6B, PLE table), quant quality table, measured
  Strata v0.1.42 + llama.cpp numbers, what didn't work.
- `docs/cmp170hx.md` — the card: unlocked 64 GB, Gen2 x4, power/cooling.
- donnager repo: `hosts/donnager/llama-swap.nix` (service pattern),
  `flake.nix` (T2 kernel, frozen nixpkgs).
