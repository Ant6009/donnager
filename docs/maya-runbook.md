# Switching donnager between strata and Maya: the runbook

Copy-pasteable. Steps 2 and 3 are the switch itself; everything else is tuning
and fixing. Nothing here rebuilds the system unless a step says so.

Last checked on donnager: 2026-11-20, Maya `v1.1.69` at `/home/maya/src`,
`NVIDIA CMP 170HX` 64 GiB, 94 GiB RAM, `/home` = `nvme0n1p4`.

## 0. What is where

| | strata | Maya |
| --- | --- | --- |
| port | 8081 | 8080 |
| engine | `/var/lib/strata/src/engine/strata` | `/home/maya/src/build/maya-hy4`, `.../build/strata_engine` |
| model the API takes | `qwen3.8-flash-next-iq3_xxs` | `hy4-flash`, `cyber-frost-3.8-ps` |
| config file | `/var/lib/strata/src/strata-iq3_xxs.json` | `/home/maya/src/maya-hy4-flash-maya-m.json`, `/home/maya/src/maya-cyber-frost.json` |
| models on disk | `/var/lib/llama/models/Qwen3.8flash` | `/home/maya/models/Hy4-Flash-Maya-M` 132 GB, `/home/maya/models/CYBER-FROST-3.8-PS` 113 GB |
| RAM held while loaded | 61.6 GiB (`MemoryCurrent`) | capped at 58 GiB by `MAYA_RAM_TIER_MAX_GB` (see §4) |
| card held while loaded | ~49-50 GiB | Hy4 alone: to be measured; it got 15.1 GiB when strata was also up |
| API key | `~/.pi/agent/auth.json` → `strata` | `/home/maya/maya-api.key`, same value under `maya` in `~/.pi/agent/auth.json` |

One of them runs at a time: `strata.service`, `llama-swap.service` and
`maya.service` carry `Conflicts=` for each other, so starting one stops another.

## 1. Look at the box first

On donnager:

```sh
systemctl is-active strata maya llama-swap
pi-backend                       # what pi is set to (rocinante)
free -g | head -2
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader
sudo sh -c 'ls -l /home/maya/src/maya-*.json'
```

Expected before a switch: `strata active`, `maya inactive`, `available` ~36 GB,
`memory.used` ~50000 MiB, both Maya configs present.

## 2. Switch to Maya (no rebuild)

```sh
sudo systemctl stop strata      # frees the 61.6 GiB and the 49 GiB of card
sudo systemctl start maya       # Conflicts= already stopped strata; this is explicit
```

Watch it load (first load takes a minute or two, then a warm-up pass):

```sh
journalctl -u maya -f
```

Three lines decide whether the run is worth using:

```
INFO CPU lane: <N> of 20992 routed experts in VRAM (<%>), the rest on <T> CPU threads from the model's file
INFO maya-hy4: Hy4-flash, 42 layers, 512 experts (16 a token), context 32768, <X> GB of VRAM over 1 GPUs, loaded in <s> s
INFO prompt chunk: <N> tokens
```

The first line is the one that matters: on 2026-11-20, with strata still holding
the card, it read `164 of 20992 routed experts in VRAM (1%)` and everything else
was computed on 12 CPU threads, which measured **2.5 tok/s prefill and 2.1 tok/s
decode**. With the card to itself, that number should be much higher; if it is
still 1%, the experts are not fitting and §4 is the fix.

## 3. Point pi at it

From rocinante, first prove the endpoint answers:

```sh
KEY=$(sed -n 's/.*"maya":{.*"key":"\([^"]*\)".*/\1/p' ~/.pi/agent/auth.json)
curl -s -H "Authorization: Bearer $KEY" http://192.168.68.128:8080/v1/models
```

Then set the default and start a **new** pi session (a running session keeps the
provider it was started with):

```sh
pi-backend maya            # -> defaultProvider maya, defaultModel hy4-flash
pi-backend maya-qwen       # -> cyber-frost-3.8-ps, same endpoint
pi-backend                 # no argument: shows the current default
```

or for one session without touching the default:

```sh
pi --provider maya --model hy4-flash
```

Both model entries and their context windows are in `~/.pi/agent/models.json`
(`hy4-flash` at 32768, `cyber-frost-3.8-ps` at 131072 - **that second number is a
guess until the CYBER-FROST config is read**: `sudo grep max-context
/home/maya/src/maya-cyber-frost.json`).

## 4. Tuning, in the order worth trying

All of these need a restart of the service, and only one model resident at a
time.

1. **Pinned expert tier** - `services.maya.ramTierMaxGb` in
   `hosts/donnager/default.nix` (default **58** GiB; `null` lets Maya choose).
   Why a cap exists: with strata stopped, `/proc/meminfo` on donnager read
   `MemTotal 94 GiB`, `MemAvailable 88.6 GiB`, `SwapFree 11 GiB`, and Maya's own
   formula (`0.7 x MemAvailable + 0.8 x SwapFree`, docs/SETTINGS.md "RAM as the
   expert pool") took **70 GiB of pinned resident tier** - 9 GiB more than strata
   keeps, leaving ~24 GiB for the kernel, the python server and the page cache.
   Maya's reach is the resident tier *plus* the experts it reads through the page
   cache *plus* the n-gram table on the SSD, so a cap is headroom, not lost reach.
   Without a rebuild: `MAYA_RAM_TIER_MAX_GB = 62` in `/home/maya/src/maya.env`
   (read by `maya.sh` at start, own line per `KEY = VALUE`, Maya logs
   `from the machine settings file: MAYA_RAM_TIER_MAX_GB=62`). A number above
   free RAM is **refused** by Maya and it falls back to its own choice.
2. **Context length** - edit `"--max-context", "32768"` in the config Maya wrote
   (`maya-hy4-flash-maya-m.json`), to 65536 or 131072, and update the matching
   `contextWindow` in `~/.pi/agent/models.json`. Hy4's KV is int8: at 32768 the
   cache is 0.73 GB, and the engine's own line said F16 rows at 32768 would not
   fit beside the dense parts.
3. **CPU lane threads** - `MAYA_CPU_THREADS = 12` in `maya.env`. 12 is what Maya
   chose here (half the 24 threads, no SMT siblings); Maya says it never goes
   above half the logical CPUs.
4. **Native vs ggml quant reads** - A/B `MAYA_NATIVE_EXPERTS = 0` in `maya.env`.
   This box was compiled `-DSTRATA_NATIVE_EXPERTS=ON` and the engine printed
   `native experts: the multi-token iq4_xs rows differ from ggml-cpu's dot in
   this build - ggml's dots for them`, i.e. the fallback path is in use for those
   row types; the other one may be faster on this card.
5. **Prompt chunk** - `--chunk N` in the config's `args`, or let `auto` keep
   choosing (it picked 1024 when the card was half taken).
6. **Drafting** - `"--mtp"` is in the config's args. If drafting is not paying
   for itself on this card, remove it and save its ~4 GiB of VRAM for experts
   (§5 measures it properly).

## 5. Measure the drafter properly (strata stopped, nothing else on the card)

`--yes` defaults to `--drafting measure`, which **loads the model twice**
(10-40 minutes). That is the step that must not run while strata is up: on
2026-11-20 it loaded 112 GB of CYBER-FROST while strata held 54.7 GB of RAM and
50 GB of the card, and the box was down to 7 GB available. The pinned setup
script now passes `--drafting on` (no measuring) and the calibration is opt-in.

In a window when nothing else needs the inference server:

```sh
sudo systemctl stop strata
sudo -u maya env CALIBRATE=1 HOME=/home/maya /etc/maya/setup.sh
sudo systemctl start maya          # or: start it, let it settle, then measure
```

`/etc/maya/setup.sh` keeps everything a previous run did, so it re-verifies
instead of re-downloading. Per model it is 5-30 minutes.

## 6. Make the switch permanent

`hosts/donnager/default.nix` currently has `services.maya.enable = true` and
`services.strata.enable = true`. The boot slot belongs to whichever of these owns
it: `services.strata.enable = true` boots strata, and Maya's unit is installed
but not `wantedBy` (`hosts/donnager/maya.nix` gates `wantedBy` on
`!config.services.strata.enable`). To make Maya the boot backend:

```nix
services.strata.enable = false;   # maya is already true
```

then `sudo nixos-rebuild switch --flake .#donnager`. After that Maya starts at
boot with the cap in §4 and strata is not pulled in at all.

## 7. Go back to strata

```sh
sudo systemctl start strata       # Conflicts= stops maya
```

Budget minutes either way: Maya unloads by ending the engine process, strata has
a park/checkpoint path. `/v1/models` keeps listing a Maya model after an unload;
the next request pays for the load again (~1 minute for Hy4 before its first
token, `idle_unload_s = 900` is in both configs).

## 8. Two models, one Maya

Hy4-Flash and CYBER-FROST live in the same install on the same port. Switch
inside Maya instead of switching services:

```sh
curl -s -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"cyber-frost-3.8-ps"}' http://127.0.0.1:8080/models/load
curl -s -X POST -H "Authorization: Bearer $KEY" http://127.0.0.1:8080/models/unload
curl -s -N  -H "Authorization: Bearer $KEY" http://127.0.0.1:8080/models/sse   # watch it
```

Or just send the other model name in the request - a request for a model that is
not loaded swaps to it, and the first token waits for the load. Only one is
resident at a time: Hy4 Maya-M wants ~76 GB of RAM+VRAM and CYBER-FROST wants
~84 GB, and the machine has 94 GiB.

## 9. If it does not come up

| Symptom | Cause and fix |
| --- | --- |
| `skipped, unmet condition check ConditionPathExists=/home/maya/src/maya.sh` | Maya is enabled but §4.2 of docs/maya.md has not been run. Nothing is broken and nothing else was disturbed; run the setup. Note that `systemctl start maya` still stops strata even when it is skipped this way. |
| unit exists but nothing at boot while you expected Maya | `services.strata.enable` is still `true` - the boot slot is strata's (§6). |
| `Importing the numpy C-extensions failed ... libstdc++.so.6: cannot open shared object file` | pip wheels in `/home/maya/src/.venv` need libstdc++ on `LD_LIBRARY_PATH`. The unit carries it (`hosts/donnager/maya.nix`) and `devShells.maya` exports it; a manual run must be inside `nix develop`. |
| `fatal error: cuda_profiler_api.h: No such file or directory` or `nvtx3/nvToolsExt.h: No such file or directory` | CUDA 13 splits those out of cudart; `devShells.maya` installs `cudaPackages.cuda_profiler_api` and `cudaPackages.cuda_nvtx`. If Maya adds another CUDA header, that is the place to add its package. |
| cmake: `Could not start dynamically linked executable: .../.venv/bin/ninja` | Maya prefers `.venv/bin/<tool>` over PATH and pip wheel binaries are not executable on NixOS. `fix_venv_tools` in `/etc/maya/setup.sh` links the shell's ninja and cmake over them, and the setup retries once. |
| `repository path '/etc/nixos' is not owned by current user` / `detected dubious ownership` | nix and git both refuse another user's repository. The setup copies `flake.nix` + `flake.lock` into `/home/maya/flake` and uses that for `nix develop`. |
| `Please make sure you have the correct access rights` when pulling | `git pull` in `/etc/nixos` as antoine, not with `sudo`: root has no GitHub key. Rebuild with `sudo nixos-rebuild`. |
| `CUDA driver is a stub library` | RUNPATH points at CUDA's stub `libcuda`. The unit sets `LD_LIBRARY_PATH=/run/opengl-driver/lib:...` which beats it. |
| RAM runs out during a load | Something else is resident: `ps -eo rss,comm --sort=-rss | head`. strata is the one that does this (54-61 GB). Stop it first. |
