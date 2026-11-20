# donnager

NixOS configuration for **donnager**, a headless Mac Pro 7,1 (T2) running as a
local LLM inference server.

## Hardware

- Mac Pro 7,1 (2019), T2 chip — T2-patched kernel 6.18.44 via `nixos-hardware` `apple-t2`
- NVIDIA CMP 170HX 64 GB — the inference card. Driver pinned at 610.57.04 with the cmpunlocker patches (`hosts/donnager/nvidia.nix`, docs/cmp170hx.md); llama-server runs `--device CUDA0`, strata is a CUDA build
- AMD Radeon Pro Vega II — used by nothing. `hosts/donnager/gpu.nix` no longer configures AMD/RADV and mesa is out of the closure; the card is being sold
- Wired 10GbE, behind a NAT router (the LAN is the trust boundary)

## Services

| Service    | Port | Notes                                                        |
|------------|------|--------------------------------------------------------------|
| SSH        | 22   | keys only, no root login                                     |
| open-webui | 3000 | browser UI, password auth, web search via searxng            |
| mcp-nixos  | 8001 | NixOS MCP server (HTTP), for pi on the LAN                  |
| searxng    | 8888 | private metasearch; secret key via agenix, limiter off       |
| llama-swap | 9292 | model router for `llama-server` (CUDA); OpenAI-compatible    |
| strata     | 8081 | second inference server, out-of-tree build (docs/strata.md)  |
| maya       | 8080 | Project Maya: Hy4-Flash + Qwen-3.8-Flash-Next in one engine, out-of-tree build (docs/maya.md) |
| open-terminal | 8000 | agent computer for Open WebUI; 127.0.0.1 only, no open port |

Models live in `/var/lib/llama/models/` (not in git — see `.gitignore`);
Maya's models live in `/home/maya/models` (~245 GB measured for both model sets,
on `nvme0n1p4`).
llama-swap unloads models after 15 min idle to free VRAM; each model pins its
own context size / quantization / chat template (Qwen uses the pinned
froggeric fixed chat template, fetched by hash).

**One big model at a time.** strata, llama-swap and maya `Conflicts=` each
other: the card and the 94 GB of RAM only hold one of them. Which one boots is
`services.strata.enable` (`hosts/donnager/maya.nix` gates its `wantedBy` on the
negation, so `services.maya.enable = true` only installs the unit) plus a
rebuild; `systemctl start strata` (or
`maya`, or `llama-swap`) is the one-command swap without a rebuild — it stops
the other. Expect minutes either way: Maya's pinned expert tier is capped at
58 GiB by `services.maya.ramTierMaxGb` (docs/maya.md §4.5 explains the number), it
still wants the rest of the pool through the page cache, and it takes minutes to
load and to hand the card back (docs/maya.md §4.4). strata's park/checkpoint path
is the fast one.
**Do the switch by hand with [docs/maya-runbook.md](docs/maya-runbook.md)** -
stop strata, start maya, point pi at :8080, which log lines tell you whether the
experts landed on the card or on the CPU lane, and the tuning knobs in order.

Inside Maya there is a second, cheaper switch: it runs Hy4-Flash
(`hy4-flash`) and Qwen-3.8-Flash-Next (`cyber-frost-3.8-ps`) in one install on
one port, so changing model is a model name in the request or one
`POST /models/load` (docs/maya.md §4.4).

Fans are driven by [t2fanrd](https://github.com/GnomedDev/T2FanRD) (the T2 case
fans are the only cooling, and Fan1 is the rear GPU exhaust — re-check the
profile once the passively cooled Vega II is physically gone).

## Repository layout

```
flake.nix                     flake entrypoint (nixos-unstable + nixpkgs-frozen for the
                              kernel + apple-t2 + t2fanrd + agenix + llmNixpkgs)
hardware-configuration.nix    disk layout (nixos-generate-config)
hosts/donnager/               host config: services, GPU, fans, firewall
modules/git/                  shared /etc/gitconfig defaults (identity set per-user)
modules/mcp-servers/          generic module: run MCP servers as hardened systemd services
docs/                         per-service notes (cmp170hx, strata, maya,
                              open-terminal, phone audio)
secrets/                      age-encrypted secrets (public keys only; blobs decrypt
                              at activation with the machine's SSH host key)
```

## Building / deploying

```sh
nixos-rebuild switch --flake .#donnager
```

The flake uses the `cache.soopy.moe` binary cache for the T2-patched kernel
(saves ~1h+ of compilation). `/boot` is a 300M partition, so systemd-boot is
capped at 5 entries — old generations are pruned automatically.

### Updating pins

Never a bare `nix flake update`: it also moves `nixpkgs-frozen`, which pins the
T2 kernel (6.18.44 is the last 6.18.y the t2linux patches apply to). Named
updates only, each as its own commit:

```sh
nix flake update llmNixpkgs   # open-terminal today; open-webui / llama-cpp-cuda later
nix flake update nixpkgs      # full userspace bump: llama-cpp, mesa, python, open-webui
```

Unfree packages (open-webui, the NVIDIA driver) are not in cache.nixos.org, so
expect a local build of those after a bump.

### Out-of-tree engines

The big-model engines are built outside the Nix store's closure; the rebuild
carries only their systemd units and a pinned setup script:

| Engine | Lives in | Build shell | Unit |
| --- | --- | --- | --- |
| strata | `/var/lib/strata/src` | the Strata repo's own `nix develop` | `hosts/donnager/strata.nix`, `/etc/strata/setup.sh` |
| Project Maya | `/home/maya/src` (models in `/home/maya/models`) | `nix develop .#maya` (nvcc 13.4 for sm_80, gcc 13 host compiler) | `hosts/donnager/maya.nix`, `/etc/maya/setup.sh` |

## Secrets (agenix)

Secrets are age-encrypted in `secrets/*.age` and committed; they decrypt at
activation using the machine's SSH host private key (module default identity).
The public keys in `secrets/secrets.nix` are safe to share.

```sh
# add a new secret
RULES=./secrets/secrets.nix nix run github:ryantm/agenix -- -e secrets/<name>.age

# read one back (on donnager)
sudo nix run github:ryantm/agenix -- -d secrets/<name>.age
```
