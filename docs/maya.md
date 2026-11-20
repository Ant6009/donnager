# Running Project Maya (Hy4-Flash + Qwen-3.8-Flash-Next) on donnager — work plan

Status: **written, not run**. `hosts/donnager/maya.nix` ships with
`services.maya.enable = false`, strata stays on. Nothing is downloaded or
built until §4.2 has been run by hand on donnager.

Research current as of 2026-11-20 against Project Maya `main` at
`e9cb6510e0922ca608bc3df18507a147670766a4` (tag `v1.1.69`), cloned to
`/tmp/project-maya` for reading.

---

## 1. What Maya is, and what "one engine, two models" means

[Project Maya](https://github.com/mw00/project-maya) is an inference engine
for the giant open MoE models: GLM-5.3, GLM-5.3-Flash, DeepSeek-V4.1-Flash-1017,
MiniMax-M3.1-Flash and, since **v1.1.68 (2026-11-19, PR #1040 by
@needmorevram)**, **Hy4-Flash** (Tencent's 220B). Each model gets its own
compiled engine (`build/maya`, `maya-hy4`, `maya-ds4`, `maya-mm3`), and every
one of them keeps the model in three tiers: the most-used routed experts in
VRAM, the next-most-used in pinned RAM, and the rest read from the NVMe file
while the model answers. The n-gram tables (Hy4's is 63.4 GB, Qwen's 52 GB)
always stay on the SSD and never count toward memory.

It also gives us, out of the box:

- an OpenAI-compatible API at `/v1` **and** Anthropic's at `/v1/messages`;
- llama.cpp's model-management endpoints `POST /models/load`,
  `POST /models/unload`, `GET /models/sse` (`MAYA_MODEL_MANAGEMENT=1`, on by
  default) plus `/api/tags`, `/api/ps`, `/api/pull`, `/api/delete`;
- **a request naming a model that is not loaded swaps to it**, and `keep_alive`
  unloads it when idle;
- `idle_unload_s` (config) / `--idle-unload 900` (command line): after that
  many idle seconds the engine ends and hands back its VRAM **and its pinned
  RAM tier** (an RTX 3090 with Maya-S24: 22.9 GB VRAM and 79 GB RAM given
  back), the dashboard keeps listing the model as `unloaded`, and the next
  request reloads it (about a minute before the first token).

**Why option 2.** Maya runs Qwen-3.8-Flash-Next too (`--model cyber-frost`,
peasantsmith's Q5_K/IQ4_NL GGUF of Blackfrost-AI's CYBER-FROST-3.8 fine-tune),
so Hy4-Flash and the QFN model live in **one install on one port**. Switching
between them is a model name in the request, or one `POST /models/load`: no
service juggling, no rebuild, no second provider endpoint to keep aligned. The
cost is honest and unmeasured: QFN leaves strata's engine — tuned for this card
over a month of work in docs/strata.md — for Maya's Qwen path. strata stays
installed as the fallback, one `systemctl start strata` away (§4.4).

## 2. What this box has to work with

Measured on donnager 2026-11-20 (`ssh donnager`):

| | |
| --- | --- |
| GPU | CMP 170HX, 65536 MiB, cc 8.0, driver 610.57.04 |
| Host RAM | 94 GiB total; strata alone is 56 GiB used, ~38 GiB available |
| CPU | Xeon W-3235, 12 cores / 24 threads |
| Disk | `/` on `nvme0n1p3`, 267 GB free; `/home` on `nvme0n1p4` (same NVMe), 724 GB free |
| Live backends | `strata` active, `llama-swap` inactive |
| PCIe | **x4, Gen1 (~0.85 GB/s measured, ~1.7 with the Gen2 unlock)** — docs/cmp170hx.md §1 |

Maya sizes a model by **VRAM + RAM together** (`docs/MEMORY.md`): this box is
one 158 GB pool, which is the top of its recommended band for Hy4-Flash
Maya-M (80-96) and inside it for Maya-L (104-128).

| Hy4-Flash quant | held in RAM+VRAM | model file | meant for | non-expert VRAM at 32K |
| --- | --- | ---: | --- | ---: |
| Maya-XS (2-bit experts) | 52 GB | 44.8 GB | 56-64 | 9.83 GiB |
| Maya-S (2/3-bit) | 64 GB | 53.0 GB | 68-80 | 10.13 GiB |
| **Maya-M (3-bit, 4-bit on 7 layers)** | **76 GB** | **68.4 GB** | **80-96** | **10.99 GiB** |
| Maya-L (4-bit, 5-bit on 5 layers) | 100 GB | 89.5 GB | 104-128 | 11.12 GiB |

Every size shares one 63.4 GB n-gram table (hard-linked into each folder), plus
the MTP block file (7.5 GB on SSD, about 4 GiB of VRAM when drafting) and a
DFly2 drafter (0.9 GB, ~0.7-0.9 GiB of VRAM) for when the MTP block does not
fit. Disk for Maya-M: **~141 GB**. CYBER-FROST is one 112.5 GB GGUF plus its
0.9 GB mmproj: **~113 GB**. Both together, ~254 GB, which is why
`--models-dir` points at `/home` and not at `/`.

**Maya-M is the pick.** Everything that is not a routed expert needs ~11 GiB of
VRAM at a 32K context, so the card has ~52 GiB for the expert pool and Maya-M's
76 GB set is nearly all resident: only a slice lands in the RAM tier. Maya-L
fits the pool but parks ~40 GB of experts out of VRAM. Both are inside what the
box can hold; M is the speed choice, L is the quality choice, and switching
between two Hy4 sizes is `--setup --hy4-quant maya-l` later (same model name,
same config).

## 3. The PCIe link is the open question

Maya's tiering assumes a normal x16 link. `docs/AGENT_BENCH.md` counts
`ram_fetch` as "RAM-tier experts fetched **over PCIe** a token", and its own
calibration log (docs/DGX_SPARK.md) compares the two paths directly:

```
CPU lane: 13 threads, an expert 0.171 ms on the CPU vs 0.117 ms over PCIe
```

That PCIe figure is a healthy link. On a Gen1 x4 CMP 170HX the same transfer is
30-50x slower, so Maya's per-expert choice should land on the CPU lane, and
decode speed then belongs to the 12-core Xeon and 8-channel DDR4 rather than to
the card. For Hy4-Flash specifically this is the designed path, not a
degradation: `docs/MEMORY.md` — "everything but the routed experts has to fit
on the card; the experts that do not fit are **computed on the CPU from RAM**".
The V100 reports in the changelog (16 GB and 12 GB cards, "with the CPU
computing the other experts") are the closest published analogue for the
resident-expert fraction we will have.

What to read on the first run: the engine's load lines for the expert pool size
and the CPU/PCIe choice, `nvidia-smi` for what the card actually holds, and
Maya's **Monitor** page for the per-GPU fill. `./maya.sh --report` writes
`maya-report.txt` with the hardware, the setup and the engine's speed lines.
`./maya.sh --calibrate` / `--speed-calibration` are what tune the CPU lanes, and
they have to run in a terminal: a service start measures nothing.

Build side: `CMakeLists.txt` needs `find_package(CUDAToolkit REQUIRED)`,
`CMakeLists.txt:110` defaults `CMAKE_CUDA_ARCHITECTURES` to 120, but
`maya.py:arch_setting` overrides it with the compute capabilities of the cards
it picked, so the 170HX is compiled for 80 without being told. Maya finds nvcc
from `PATH`/`CUDA_PATH`/`/usr/local/cuda*`/`/opt/cuda*`, and `nvcc_range` accepts
CUDA >= 12.0 for sm_80 with no upper bound (CUDA 13 is fine for Ampere). The
flake's `devShells.maya` supplies nvcc 13.4.92 with **gcc 13** as the host
compiler, because nixpkgs' own stdenv here is gcc 16.2 and nvcc will refuse a
host compiler that new; `--host-compiler g++-13` is the escape hatch if it ever
picks one anyway.

## 4. Install plan

### 4.1 Pre-flight

1. Disk: `df -h /home` — needs ~254 GB for both models, ~141 GB for Hy4 alone.
2. Outbound HTTPS to huggingface.co (the setup prints every download and its
   sha256 before starting it; it continues where a download stopped).
3. **Done 2026-11-20.** The rebuild with `services.maya.enable = true` created
   uid/gid `maya` (988/986), `/home/maya` 0750 maya:maya, `/home/maya/models`,
   `/etc/maya/setup.sh` 0755, and opened 8080 (nothing listens on it yet). It
   started no service and left strata running.
4. **Done 2026-11-20:** `/home/maya/maya-api.key` (0600, maya-owned) already
   holds the API key, generated before §4.2 so the pi and Open WebUI clients can
   be configured first. The setup script's key order is existing config, then
   this file, then generate, so it reuses this one. pi's copy is in
   `~/.pi/agent/auth.json` as `maya` (docs/maya.md §4.4).

### 4.2 One-time setup (on donnager)

The whole pinned command lives in `hosts/donnager/files/maya-setup.sh`, which
the module installs at `/etc/maya/setup.sh`:

```sh
sudo -u maya /etc/maya/setup.sh
```

What it pins, in order:

| Step | Command |
| --- | --- |
| Build shell | `nix develop /etc/nixos#maya -c ...` (self-wrapping, only when `nvcc` is missing) |
| Checkout | `git clone https://github.com/mw00/project-maya.git /home/maya/src` at `v1.1.69` |
| API key | reuse the key an existing `maya-*.json` carries, else `/home/maya/maya-api.key`, else generate one and print it once |
| Hy4-Flash | `./maya.sh --setup --model hy4-flash-maya-m --models-dir /home/maya/models --host 0.0.0.0 --port 8080 --api-key "$KEY" --yes --download-model` |
| Qwen | the same with `--model cyber-frost` |
| Calibrate | `./maya.sh --config <cfg> --speed-calibration --no-start` for each config (skip with `CALIBRATE=0`) |
| Idle unload | writes `"idle_unload_s": 900` into each config (skip with `IDLE_UNLOAD=0`) |
| Verify | lists the `maya-*.json` files it wrote and each one's model name, host, port, context |

Flags deliberately **not** pinned: `--context` (Hy4 needs more VRAM the longer
the context and Maya "picks the context that fits the card", 4K to 1M — pin it
later with `--setup --context N` once the load lines are known), `--no-vision`
(both models read pictures; Hy4's needs no VRAM of its own since v1.1.69),
`--drafting` (the MTP block costs ~4 GiB of VRAM that would otherwise hold
experts; Maya measures whether it is faster here, `--drafting off` to skip it).

`--yes` takes the recommended answers; `--download-model` is what actually lets
the download start; `--plain` gets the text setup if the script is ever run from
a pipe. The setup screen's whole output is also in `maya-setup.log`.

Updating later: `cd /home/maya/src && git fetch && git checkout <tag>`, then
`./maya.sh` (recompiles only what changed, does not download the model again).
`--import-model FOLDER` / `--model-dir DIR` take files downloaded some other
way, matched by size and sha256.

### 4.3 NixOS module `hosts/donnager/llama-swap.nix`, `strata.nix`, `maya.nix`

`hosts/donnager/maya.nix`: `services.maya.enable` (default **false**),
`srcDir` (`/home/maya/src`), `modelsDir` (`/home/maya/models`), `startConfig`
(`maya-hy4-flash.json`). The unit is upstream's own systemd shape:

```nix
ExecStart = "/home/maya/src/maya.sh --config /home/maya/src/maya-hy4-flash.json";
```

**Who owns the boot slot.** The repo's existing rule is kept: `services.strata.enable`
alone decides what boots (`hosts/donnager/llama-swap.nix` gates its `wantedBy` the
same way). `services.maya.enable = true` only **installs** the unit; its
`wantedBy` is `lib.mkIf (!config.services.strata.enable) [ "multi-user.target" ]`.
So Maya is installed now and starts at boot only when strata is switched off.
Moving to it afterwards is either that one flag plus a rebuild, or nothing at all:
`systemctl start maya` stops strata through `Conflicts=`. Verified by eval:
with both flags on, `wantedBy` is empty for maya and `multi-user.target` for
strata.

**The guard that makes installing early safe.** `unitConfig.ConditionPathExists =
"/home/maya/src/maya.sh"`. Without it, an enabled Maya on a box where §4.2 has not
run would fail ExecStart every time and `Restart = "on-failure"` would re-fail it
every 30 seconds forever.

Measured on donnager 2026-11-20 with the engine absent (`sudo systemctl start maya`):
the unit is skipped cleanly - journal `Project Maya inference engine ... skipped,
unmet condition check ConditionPathExists=/home/maya/src/maya.sh`, `Result=success`,
`ActiveState=inactive`, no restart attempts. What the condition does **not** do is
block `Conflicts=`: strata went inactive anyway and took 5 s to bring back with
`sudo systemctl start strata`. So the guard prevents the failure loop, not the
hand-over: starting Maya before §4.2 has run is harmless but pointless, and it costs
strata until you start it again.

- Port, host and API key are **not** in the unit: they are in the config the
  setup script wrote. Passing `--port` to `maya.sh --config ...` is not what
  upstream's systemd recipe does.
- `TimeoutStartSec = 3600`, `TimeoutStopSec = 600`: a big model at a long
  context takes minutes to load (it pins its expert tier and warms caches) and
  minutes to save conversations and free the GPUs. systemd kills a unit that is
  not up in time and then loads it again, forever.
- `Environment = HOME=/home/maya` (Maya keeps `~/.config/project-maya/drive-reads.txt`,
  a system user's default `/var/empty` is not writable) and
  `LD_LIBRARY_PATH=/run/opengl-driver/lib` for the stub-libcuda trap recorded in
  `hosts/donnager/strata.nix`.
- `LimitMEMLOCK = "infinity"` for the pinned expert tier, same as strata's PLE
  table. **Not measured for Maya yet** (§5).
- `conflicts = [ "strata.service" "llama-swap.service" ]`, and the reverse in
  `strata.nix` and `llama-swap.nix`: Maya pins "most of the free RAM (all but
  about 6 GB)" for its expert tier while strata alone is 56.4 GiB RSS of
  94 GiB, so no two of these run at once.
- `systemd.tmpfiles.rules` create `/home/maya` (0750 maya:maya) and
  `modelsDir` at activation.

Flake side: `devShells."${system}".maya` from `llmPkgs` —
`cudaPackages.cuda_nvcc` (13.4.92), `cudaPackages.cuda_cudart`,
`cudaPackages.libcublas` (the toolkit's `CUDA::cublas`, which `CMakeLists.txt:193`
links), `gcc13`/`g++13` exported as `CC`/`CXX`, `cmake`, `ninja`, `make`,
`python3`, `git`, `pkg-config`. It is a build shell, not a runtime dependency:
the service runs the out-of-tree engine.

Both flag states were checked with `nix eval` (2026-11-20), not just written:
with `enable = false` the `maya` user, `/home/maya`, `/home/maya/models`,
`/etc/maya/setup.sh` and port 8080 exist and no unit does, `strata` is
untouched (`wantedBy` stays empty on llama-swap, `conflicts` on strata is
`[ "llama-swap.service" ]`); with `enable = true` the unit resolves to
`ExecStart = /home/maya/src/maya.sh --config /home/maya/src/maya-hy4-flash.json`,
`Environment = [ HOME=/home/maya LD_LIBRARY_PATH=/run/opengl-driver/lib ]`,
`TimeoutStartSec 3600`, `TimeoutStopSec 600`, `LimitMEMLOCK infinity`,
`conflicts = [ strata.service llama-swap.service ]`, and llama-swap gains the
`maya.service` conflict. That eval is also what caught the module-merge trap
recorded at the top of `hosts/donnager/maya.nix`.

### 4.4 Switching

**Inside Maya (the point of option 2).** One endpoint,
`http://192.168.68.128:8080/v1`, and two model names — Maya's ids are fixed in
`maya.py`: `hy4-flash` (`HY4_MODEL_NAME`, line 845) and `cyber-frost-3.8-ps`
(`QWEN_MODEL_NAME`, line 761; unsloth's smaller `qwen3.8-flash-next` if that
quant is ever set up). Three ways to switch:

1. Send the other model name — "a request for a model that is not loaded swaps
   to it". First token waits for the load (expect minutes for these sizes).
2. Warm it first: `curl -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d '{"model":"hy4-flash"}' http://127.0.0.1:8080/models/load`, and `POST /models/unload` to give the card back. `GET /models/sse` watches the state.
3. Maya's own dashboard on `http://127.0.0.1:8080`: the Models page loads,
   unloads and deletes every model set up on the machine.

`idle_unload_s = 900` (§4.2) is what keeps the card and the RAM free between
sessions instead of holding 76 GB of pinned tier overnight.

**Clients.**

- **pi (rocinante):** configured 2026-11-20. Provider `maya` in
  `~/.pi/agent/models.json`, `baseUrl http://192.168.68.128:8080/v1`, two model
  entries (`hy4-flash` at 32K, `cyber-frost-3.8-ps` at 128K; **both context
  windows are placeholders** — set them to what §4.2 actually writes), the key in
  `~/.pi/agent/auth.json` as `{"maya":{"type":"api_key","key":"..."}}` (0600,
  outranks env vars), and `~/.local/bin/pi-backend [llama-swap|strata|maya|maya-qwen]`
  sets the default for a NEW session (`maya` → `hy4-flash`, `maya-qwen` →
  `cyber-frost-3.8-ps`); `pi --provider maya --model hy4-flash` is the immediate
  form. Nothing on 8080 answers until §4.2 has run.
- **Open WebUI (donnager):** Maya is an OpenAI-compatible endpoint at
  `http://127.0.0.1:8080/v1`; add it as a provider in the UI (per-chat pick).
  With `--host 0.0.0.0` it answers `401 missing or wrong API key` without one,
  so the key is required, not optional.

**Back to strata (the fallback).** `sudo systemctl start strata` stops maya
(`Conflicts=` both ways) and starts QFN on 8081 with the engine tuned in
docs/strata.md; `systemctl start llama-swap` for the dense Qwen3.8-27B on 9292.
Persistent choice is one flag in `hosts/donnager/default.nix`:
`services.strata.enable = true` owns the boot slot (Maya is installed but not
`wantedBy`), `false` hands the boot to Maya — then rebuild. Without a rebuild the
hand-over is `systemctl start maya` / `systemctl start strata`. Budget minutes for a
swap in either direction: Maya's load and unload are slow (§4.3), strata's park
and checkpoint paths are the fast ones.

Measured on the box 2026-11-20, before §4.2: `sudo systemctl start maya` on a machine
with no `/home/maya/src` skips maya (unmet condition) and still stops strata;
`sudo systemctl start strata` restored it 5 s later, `active` on 8081 since. Maya's
unit is `linked` (installed, not enabled), which is what `wantedBy` gated off
`!services.strata.enable` looks like in `systemctl show -p UnitFileState`.

## 5. Not verified on this box yet

Installed and checked so far (2026-11-20): the module evaluates and activates the
user, directories, setup script and firewall rule; `/etc/maya/setup.sh` is on the
box; the pi provider exists; `systemctl start maya` is wired to stop strata. Not
done: §4.2 (engine build, model downloads, calibration), so nothing listens on 8080.

Everything below is a claim from upstream's docs, not a measurement here:

1. **A second `--setup` keeps both models in one install.** The docs say the
   Models page lists "every model set up on this machine" and each model has its
   own `maya-<model>.json`, but whether a second `--setup` rewrites or keeps the
   first model's machine choices is untested. Check `ls /home/maya/src/maya-*.json`
   after both setups, and `/v1/models` after start.
2. **The config filenames.** `model_name` for Hy4 is `hy4-flash`, so
   `startConfig = maya-hy4-flash.json` is the expected name (upstream names the
   config after the model, `maya-<model>.json`); the setup script prints what it
   actually wrote. If it differs, `services.maya.startConfig` is the knob.
3. **Expert-pool residency and the CPU/PCIe choice on a Gen1 x4 link** (§3):
   read the load lines before believing any speed number.
4. **Whether Hy4's n-gram table and CYBER-FROST's table can share page cache
   with everything else** on a single NVMe while strata's 26.8 GiB PLE table is
   also mapped — they cannot run together, but the swap sequence is untested.
5. `LimitMEMLOCK=infinity` and Maya's pinned tier: like strata, a cgroup
   `MemoryMax` would count the reclaimable page cache holding the mmap'd tables,
   so nothing is capped until it is measured.
6. The MTP block file is published on the Hub as a `.gguf_file` (outside the
   Hub's size list) at `mtp_revision`; `tools/hy4/download.json` says the setup
   "takes only a copy already on the PC" until it is uploaded. If drafting is
   missing, Maya falls back to DFly2 (0.7-0.9 GiB of VRAM) or no drafting.
7. Hy4-Flash has **no `--parallel`** yet (one request at a time). pi's
   `parallel_requests: 4` against a Maya model is therefore not a thing to
   expect.
8. Maya's web UI keeps chats in the browser and its MCP-tool and file-reading
   features are untested against Open WebUI here.

## 6. Rollback

`services.maya.enable = false` + rebuild: the unit, the `maya` user and the
etcpin disappear, strata comes back at boot, models stay on disk. `nixos-rebuild
--rollback` for the previous generation. Deleting the model files is
`rm -rf /home/maya/models/*` or Maya's own Models page.

## 7. Sources

- [Project Maya](https://github.com/mw00/project-maya), `main` at
  `e9cb6510e092` / tag `v1.1.69` (2026-11-20); Hy4-Flash landed in `v1.1.68`
  (2026-11-19, PR #1040 by @needmorevram).
- `docs/MODELS.md` (Hy4 sizes, 185-262; Qwen/CYBER-FROST), `docs/MEMORY.md`
  (pool sizing, "The floor"), `docs/SETUP.md` (options table 186-219, systemd
  recipe 146-185, idle unload 232-250), `docs/SETTINGS.md` (Hy4-Flash
  2330-2430, Qwen-3.8-Flash-Next 2262-2330, `MAYA_MODEL_MANAGEMENT` 233).
- `tools/hy4/download.json` (file names, sizes, sha256, `memory_gb`,
  `plan.need_gib`, MTP and DFly2 drafters), `tools/qwen/download.json`
  (CYBER-FROST-3.8-PS 112.5 GB at commit `32867bb9e228`, mmproj from unsloth at
  `766911a6b736`).
- `maya.py` `nvcc_range` (1477-1481), `find_nvcc`/`nvcc_candidates`
  (1484-1525), `arch_setting` (2598-2603), model names (761, 779, 845);
  `CMakeLists.txt:106-193` (`CUDAToolkit`, `CUDA::cublas`).
- Model cards: [peasantsmith/Hy4-Flash-Maya-GGUF](https://huggingface.co/peasantsmith/Hy4-Flash-Maya-GGUF),
  [tencent/Hy4-flash](https://huggingface.co/tencent/Hy4-flash) (Tencent Hy
  License 1.0, `LICENSE.hy4-flash`),
  [peasantsmith/CYBER-FROST-3.8-PS-GUFF](https://huggingface.co/peasantsmith/CYBER-FROST-3.8-PS-GUFF)
  (Qwen Community License 1.0, `LICENSE.qwen-community-1.0`).
- donnager's own numbers: `docs/strata.md` §4.5 (56.4 GiB RSS of 94 GiB at
  256K), `docs/cmp170hx.md` §1 (x4, Gen1, ~0.85 GB/s measured).
