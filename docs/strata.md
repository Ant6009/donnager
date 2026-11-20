# Running Strata (Qwen3.8-Flash-Next) on donnager — work plan

Status: **deployed**. `services.strata.enable = true`, the unit is active on
donnerger, pictures are on (`--vision gpu`), and the 256K numbers in §4.5 are
measured (2026-11-03). The §5 stage-2 env switches are still commented out in
`hosts/donnager/strata.nix` pending that baseline, and §9's open items stand.
Research current as of 2026-10-29 against Strata `main` at `46c152a`
(2026-10-28) and the sm_80 tuning data from issue #3712 / PR #3779.

2026-11-20: Project Maya (docs/maya.md) is the alternative host for the same
QFN model, on port 8080, with Hy4-Flash beside it. §4.3/§4.4 now describe three
backends; strata stays enabled until Maya is measured on this card.
Quant: **IQ3_XXS** (decided 2026-11-03); the model pack is local at
`/var/lib/llama/models/Qwen3.8flash`.
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

Quant decision (**IQ3_XXS**, 2026-11-03): the ~47 GB expert shard fits
entirely in the unlocked 64 GB of HBM2e — near-100% expert hit rate, which
is exactly the condition under which donnager's weak points (AVX2-only
Xeon, Gen2 x4 link) stop mattering: steady-state decode and prefill never
touch the host link. The link only matters for cold model load and
conversation KV park/restore (§5, PR 4). IQ3_XXS also buys the quality
step up (§7.2: 92.57 vs 89.16 task average). Fallbacks: IQ2_XS if VRAM
headroom is needed, Q2_0 for raw speed.

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

1. **Disk:** the IQ3_XXS pack is local (`/var/lib/llama/models/Qwen3.8flash`),
   so no ~70 GB model download — budget for venv (the nvidia pip wheels
   are multi-GB) + build artifacts + the MTP head if not already there.
   Also `ls` that folder: it must contain the GSQ-RCO IQ3_XXS shards
   (two: native + PLE) for `--gguf-dir` to work; the unsloth UD-Q4_K_XL
   4-shard layout there is llama-swap's and its `--gguf-dir` compatibility
   is unverified (if the folder only has that, drop `--gguf-dir` and let
   setup.py download).
2. **VRAM:** `nvidia-smi` → 65536 MiB, name "NVIDIA CMP 170HX" (unlocked).
   A card reporting 8192 MiB voids the resident-experts premise; stop.
   IQ3_XXS budget: ~47 GB shard + ~1 GB KV @32K + MTP ≈ 51–54 GB — fits,
   with ~10 GB to spare.
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

First checkout (done 2026-11-03):

```sh
git clone https://github.com/Niko1221/Strata /var/lib/strata/src
cd /var/lib/strata/src
nix develop        # the repo's own flake: CUDA 13.0 + cmake + ninja + python3
```

Everything after that goes through the pinned wrapper this repo carries at
`hosts/donnager/files/strata-setup.sh`, installed by the module as
`/etc/strata/setup.sh`. It spells out every flag, so a rebuild cannot
silently regenerate a smaller context, a different KV type, a loopback-only
listen address or a new API key:

```sh
sudo -u strata /etc/strata/setup.sh            # reuse the built engine
sudo -u strata /etc/strata/setup.sh --build    # recompile for sm_80 (self-wraps nix develop)
```

which is, with the flags expanded:

```sh
./setup.sh --yes --family qwen --model IQ3_XXS --context 262144 --kv int8 \
           --vision gpu --mtp on --host 0.0.0.0 --port 8081 \
           --api-key "$KEY" --gguf-dir /var/lib/llama/models/Qwen3.8flash \
           --no-browser --no-start
```

Pictures need two things the pinned script cannot fetch on this box, and both
are checked before setup runs:

1. **The picture reader is a second binary** (`engine/strata-vision`, llama.cpp's
   `mtmd`). The 2026-11-03 build compiled the engine with `--vision no`, so
   `engine/BUILD.json` says `"vision": "none"` and there is no reader beside
   it. `--vision gpu` without `--build` only prints *"this engine has no image
   encoder: images off (run setup again with --build to compile it)"* and stays
   text-only. With `--build`, the engine's own source hash is unchanged, so
   only `tools/vision` compiles for sm_80 (10-20 minutes, once) and
   `BUILD.json` is re-stamped `"vision": "gpu"`.
2. **With `--gguf-dir`, setup downloads nothing.** It wants the pinned mmproj in
   that folder under its pinned name, and fails with *"put
   mmproj-Qwen3.8-Flash-Next-BF16.gguf in ... or drop --gguf-dir to download
   it"* otherwise. The pinned file is 907,543,008 bytes, sha256
   `b1a82259702816a5330d7bd7607cd9676b11780e79ff7348c21103ff3ce49bd0`, from
   [ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF](https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF)
   at the revision setup.py pins (`ed59f920…`). The folder is root-owned, so:

   ```sh
   sudo curl -L -o /var/lib/llama/models/Qwen3.8flash/mmproj-Qwen3.8-Flash-Next-BF16.gguf \
     https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF/resolve/ed59f92082b1e93c0e96d60a8b11aab089b52f09/mmproj-Qwen3.8-Flash-Next-BF16.gguf
   ```

   Unsloth's `mmproj-F16.gguf` already in that folder (904,004,000 bytes, the
   llama-swap entries' projector) is a different file: renaming it to the
   pinned name fails the size check, and setup never deletes a file you put in
   the folder yourself.

What setup then writes is config-only: `--vision` in `args` plus a `"vision"`
section (`exe`, `mmproj`, `model`, `gpu: true`, `max_tokens: 1024`). The engine
binary already knows the `--vision` flag. Step 6 rebuilds the tokenizer only
when `packs/iq3_xxs/tokenizer/vocab.json` is missing, so the pack is not
reconverted. The GPU reader keeps ~1.4 GiB of VRAM and setup reserves 700 MiB
(`--vram-reserve-mib 700`) out of the expert cache, against the ~10.7 GiB free
at load (§4.5). `--vision cpu` is the no-VRAM fallback: 300 image tokens per
picture, 3-30 s each, and it still needs `--build` for the same binary.

`--api-key` is not in git: the script re-reads the key from the existing
`strata-iq3_xxs.json`, falls back to `/var/lib/strata/strata-api.key`, and
only then generates one (printing it once, since pi holds a copy in
`rocinante:~/.pi/agent/auth.json`). The script fails if setup.py writes a
context other than 262144, and strips `--open` from the generated
`run-iq3_xxs.sh` (headless host).

What that does (each step is idempotent — re-running only does what is
missing):

1. venv (uv on NixOS) + Python packages (numpy, jinja2, nvidia CUDA libs)
2. **compiles the engine for sm_80** (no ready-made build; §3)
3. uses the local GGUFs from `--gguf-dir` (skips the HF download; the
   MTP draft layer is still fetched if missing, and the picture reader must
   already be in the folder — see the mmproj note above)
4. prepares the model for Strata
5. writes `run-<model>.sh` and starts the server on port 8081

Everything the install writes lands in the checkout itself
(`setup.py`'s `home()` is the repo root) — so `/var/lib/strata/src` is the
payload the service points at. `--context 262144` is the model's trained
context (§4.5: measured, it costs ~5 GB of parked KV in RAM, not VRAM).

Note on the model location: `/var/lib/llama/models/Qwen3.8flash` holds
both llama-swap's Qwen3.8-Flash-Next (unsloth UD-Q4_K_XL, 4 shards,
mmproj, MTP subfolder) and, per the owner, the IQ3_XXS pack for Strata.
`--gguf-dir` points at the folder; Strata's `setup.py` expects the
GSQ-RCO two-shard layout (native + PLE). The folder is read-only for
this trial — llama-swap keeps using it as before, and nothing here
writes to it.

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
is Nix-managed).

llama-swap is *not* untouched: the two backends cannot share the card, so
`hosts/donnager/llama-swap.nix` gates its `wantedBy` on `!services.strata.enable`
(and, since 2026-11-20, on `!services.maya.enable` too) and both sides carry
`Conflicts=`. With strata enabled, llama-swap is not
pulled in at boot, and `systemctl start llama-swap` stops strata instead of
deadlocking the GPU. Everything that expects 9292 (42's `llm.base_url`, Open
WebUI's first provider, pi's `llama-swap` provider entry) is dark while
strata runs — switch with `services.strata.enable = false` and a rebuild, or
`systemctl start llama-swap` for a throwaway test.

Project Maya (docs/maya.md) joined this arrangement on 2026-11-20: its unit
carries `conflicts = [ "strata.service" "llama-swap.service" ]`, and both of
those carry a conditional `maya.service` conflict back, so `systemctl start
maya` stops strata and `systemctl start strata` is the way back to the engine
and the tuning this doc records — no rebuild, minutes of load time either way.
Maya is the alternative host of the same QFN model (`--model cyber-frost`), so
it is worth measuring against strata rather than assuming either one wins.

### 4.4 Client-side switching (pi, Open WebUI)

There is no unified router in front of the backends, so each client
holds each one as a named endpoint and switching is one word:

- **pi (rocinante):** `~/.pi/agent/models.json` holds the backends as named
  endpoints (`llama-swap` → `:9292`, `strata` → `:8081`, and `maya` → `:8080`
  once docs/maya.md §4.2 has been run; as of 2026-11-20 the file carries only
  `strata`). `~/.local/bin/pi-backend [llama-swap|strata|maya]` sets the
  default (takes effect in a *new* pi
  session; the running one keeps its baked-in `PI_PROVIDER`/`PI_MODEL`),
  or immediately: `pi --provider strata --model qwen3.8-flash-next-iq3_xxs`.
- **Open WebUI (donnager):** add a second OpenAI provider at
  `http://127.0.0.1:8081/v1` in the UI; pick the backend per chat.
- **Model name:** the generated config already carries
  `model_name: qwen3.8-flash-next-iq3_xxs` (verified after the build) —
  matches the client id, nothing to pin. The API also accepts any model
  name, so this is belt-and-braces.
- **Firewall:** 8081 is opened in `default.nix` for pi on rocinante;
  Open WebUI reaches it locally, so no Caddy involvement.
- **API key:** `--host 0.0.0.0` makes setup.py require one, and the server
  answers `401 missing or wrong API key` without it (measured). pi keeps its
  copy in `~/.pi/agent/auth.json` as `{"strata":{"type":"api_key","key":"..."}}`
  (0600, and it outranks env vars and `models.json` in pi's key resolution
  order), so plain `pi` works with no `--api-key` flag. The key contains a
  `>`: quote it on any command line or it silently redirects into a file.
- **Context numbers must match the server.** pi's `models.json` is sized so
  `contextWindow + maxTokens` equals the engine's `--max-context` exactly:
  229376 + 32768 = 262144. The server does not reject a request whose prompt
  plus `max_tokens` exceeds the context, it starts prefilling and fails late
  (§4.5).

### 4.5 Context at 256K: measured (2026-11-03)

`--context 262144 --kv int8`, one client, verified with a synthetic prompt:

| Check | Result |
|---|---|
| 222,950-token prompt | accepted, HTTP 200, prefill 106 s at 2102 tok/s, decode 78.9 tok/s |
| VRAM during that prefill | flat at 52558 used / 12353 free over 55 samples |
| Steady state after | 54158 used / 10753 free of 65536 MiB (~83% occupied) |
| Engine's own accounting at load | expert cache 39.97 GiB, MTP draft 1100 MiB, prompt-ring borrow 4.00 GiB, graph windows ~140 MiB, "14332 MiB of VRAM free with everything loaded" |
| Host RAM | strata-host RSS 56.4 GiB of 94 GiB, MemAvailable ~38 GiB |

The 32K to 256K change does not load the card: the engine reserves its arena
at startup, VRAM does not grow with context length, and the extra cost lands
in system RAM as parked conversation KV, about 19 KB/token, so a 262K-token
snapshot is ~5 GB. The conversation cache budget is 8192 MiB for up to 4
parked conversations and one long conversation already pushes it past that
(`evictions=4` observed). Eviction is not failure: re-prefill runs at ~2100
tok/s, so ~2 minutes to rebuild a 250K context.

What is not safe: two heavy clients at once (11 GiB of free VRAM is one long
conversation), and llama-swap loaded alongside strata, hence the `Conflicts=`
in §4.3. The engine also runs its own host-RAM guard ("limit 94.2 GiB ... floor
2560 MiB"), which is why the unit carries no `MemoryMax` (§9.3).

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
| Quant | IQ3_XXS (47 GB shard + 29 GB PLE) | IQ3_XXS (decided 2026-11-03) |
| Context | 262K–524K, YaRN, KV streamed to RAM | 32K — KV fits in VRAM, no streaming |
| MTP / vision | on / on | on (setup fetches it) / gpu reader (§4.2) |

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
2. **`ExecStart`** — *resolved after the build*: taken from the generated
   `run-iq3_xxs.sh` (venv python + `serve/server.py` + `strata-iq3_xxs.json`,
   minus `--open`).
3. **`MemoryMax` value** — *resolved 2026-11-03: leave it unset*. A cgroup
   limit counts the reclaimable page cache holding the mmap'd PLE table and
   the expert arena, so the runbook's 40 GB guess would OOM-kill a healthy
   engine (RSS is 56.4 GiB, 26.8 GiB of it that table). The engine's own
   memory guard (floor 2560 MiB) is doing this job. Revisit only if
   `LimitMEMLOCK` goes back to its default.
4. **Disk** — confirm the NVMe has the ~70 GB *additional* headroom
   (§4.1.1) before the model download starts.
5. **Quant choice** — *resolved 2026-11-03: IQ3_XXS* (fits at 32K,
   +3.4 task-avg per ISTA, §7.2; IQ2_XS remains the VRAM-headroom
   fallback).
6. **Host header / API key** — *resolved 2026-11-03: `--host 0.0.0.0` with a
   key*, pinned through `/etc/strata/setup.sh` (§4.2) and stored client-side
   in `rocinante:~/.pi/agent/auth.json`. The key stays out of git, and it
   survives a rebuild because the script re-reads it from the generated
   config.
7. **PLE table placement** — after the build: free RAM with the table
   mapped, and page-cache behaviour under the 32K bench (§4.1.4, §6.4).
8. **Unlock revision on our card** — v0.4 vs v0.5 (+4 SMs) affects
   comparability with both references (§7.8); `docs/cmp170hx.md` records
   it.
9. **Pictures** — the pinned script asks for `--vision gpu` (§4.2). Open:
   compile `engine/strata-vision` with `sudo -u strata /etc/strata/setup.sh
   --build --vision gpu`, re-measure `nvidia-smi` after the reader starts
   (expect ~1.4 GiB used + 700 MiB reserved out of the 10.7 GiB free at load,
   §4.5), then declare the input on the client: pi's `models.json` strata model
   needs `"input": ["text", "image"]` (and a resize cap near 1568×1568, since
   `vision.max_tokens` clamps each picture at 1024 image tokens) before pi
   sends one at all.

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
