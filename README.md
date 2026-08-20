# donnager

NixOS configuration for **donnager**, a headless Mac Pro 7,1 (T2) running as a
local LLM inference server.

## Hardware

- Mac Pro 7,1 (2013), T2 chip — T2-patched kernel via `nixos-hardware` `apple-t2`
- AMD Radeon Pro Vega II (Vulkan/RADV compute for llama.cpp)
- Wired 10GbE, behind a NAT router (the LAN is the trust boundary)

## Services

| Service    | Port | Notes                                                        |
|------------|------|--------------------------------------------------------------|
| SSH        | 22   | keys only, no root login                                     |
| open-webui | 3000 | browser UI, password auth, web search via searxng            |
| mcp-nixos  | 8001 | NixOS MCP server (HTTP), for pi on the LAN                  |
| searxng    | 8888 | private metasearch; secret key via agenix, limiter off       |
| llama-swap | 9292 | model router for `llama-server` (Vulkan); OpenAI-compatible  |

Models live in `/var/lib/llama/models/` (not in git — see `.gitignore`).
llama-swap unloads models after 15 min idle to free VRAM; each model pins its
own context size / quantization / chat template (Qwen uses the pinned
froggeric fixed chat template, fetched by hash).

Fans are driven by [t2fanrd](https://github.com/GnomedDev/T2FanRD) (the Vega II
is passively cooled; T2 case fans are the only cooling).

## Repository layout

```
flake.nix                     flake entrypoint (nixos-unstable + apple-t2 + t2fanrd + agenix)
hardware-configuration.nix    disk layout (nixos-generate-config)
hosts/donnager/               host config: services, GPU, fans, firewall
modules/git/                  shared /etc/gitconfig defaults (identity set per-user)
modules/mcp-servers/          generic module: run MCP servers as hardened systemd services
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

## Secrets (agenix)

Secrets are age-encrypted in `secrets/*.age` and committed; they decrypt at
activation using the machine's SSH host private key (module default identity).
The public keys in `secrets/secrets.nix` are safe to share.

```sh
# add a new secret
RULES=./secrets/secrets.nix nix run github:ryantm/agenix -- -e secrets/<name>.age
```
