# Open Terminal on donnager

Upstream: https://github.com/open-webui/open-terminal (MIT, Python 3.11+)
Feature docs: https://docs.openwebui.com/features/open-terminal/

## What it is

Open WebUI's action layer. A FastAPI server exposing file browse/read/write,
PTY terminals, command execution, git views, notebooks and skills. Open WebUI
ingests its OpenAPI spec as tools and adds a Terminal dock, so the chat model
(Qwen3.8 through llama-swap, `--jinja` tool calling) can act on a real
filesystem instead of only talking about one.

## Shape on this box

| piece | value | why |
|---|---|---|
| package | `llmPkgs.open-terminal`, 0.14.8 | absent from the locked main nixpkgs (2026-10-23); comes from the pinned `llmNixpkgs` input instead |
| mode | bare metal systemd service | the upstream Docker image's value is its toolkit (node, build tools, Chromium + virtual desktop). 0.14.8 ships none of it, so the image buys nothing here |
| bind | `127.0.0.1:8000` | Open WebUI proxies server-side; no firewall port, LAN cannot reach it |
| user | `open-terminal`, home `/var/lib/open-terminal` | single-user mode; the file browser is rooted at HOME (`OPEN_TERMINAL_FILE_BROWSER_ROOT = "home"`) |
| key | agenix blob `/run/agenix/open-terminal`, mode 0440 `root:open-terminal` | `OPEN_TERMINAL_API_KEY_FILE` keeps the key out of the unit environment and out of the nix store |
| shell PATH | `makeBinPath` inside the service unit | the agent's tools are declared where the agent runs, not in `environment.systemPackages` |
| caps | MemoryHigh 8G, MemoryMax 16G, TasksMax 1024, 8 sessions, 3600 s per command | a runaway build must not starve llama-server (94 GB box) |

## Enable it

1. A committed blob with a generated key already exists. To replace the key
   (from the repo root; opens `$EDITOR`, paste a new 64-hex key, save, quit):

   ```sh
   RULES=./secrets/secrets.nix nix run github:ryantm/agenix -- -e secrets/open-terminal.age
   ```

2. Read the current key on donnager (needed once, to paste into Open WebUI):

   ```sh
   sudo nix run github:ryantm/agenix -- -d secrets/open-terminal.age
   ```

3. `nixos-rebuild switch --flake .#donnager`

Never fix a missing package here with a bare `nix flake update`: that moves
`nixpkgs-frozen` too (the T2 kernel pin, 6.18.44). The LLM-tooling input has
its own update: `nix flake update llmNixpkgs`.

## Connect it in Open WebUI

Admin Settings -> Integrations -> Open Terminal -> add a server:

- URL `http://127.0.0.1:8000`
- API key: the plaintext from step 2
- Auth: `Bearer` (default)
- Chat uploads `Default`, Working Directory Context on, User shell tools
  `Automatic`, Forward cookies off

Then `systemctl restart open-webui` once: it reads and caches each terminal
connection's OpenAPI spec at startup (`backend/open_webui/utils/tools.py`,
`set_terminal_servers`). The unit ordering in `open-terminal.nix` already puts
open-webui after open-terminal at boot.

Select the terminal in a chat's terminal menu. Deployed open-webui is 0.12.3 and
already carries this integration; 0.13.x adds the git panel, the Browser tab and
the agent adapters (Codex / Claude Code / Pi showing up as models).

## Verify

```sh
systemctl status open-terminal
journalctl -u open-terminal -b | head -20        # banner + "Local: http://127.0.0.1:8000"
ss -ltnp | grep 8000                             # must show 127.0.0.1 only

KEY=$(sudo nix run github:ryantm/agenix -- -d secrets/open-terminal.age)
curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:8000/health
curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:8000/execute \
  -H 'Content-Type: application/json' \
  -d '{"command":"id; uname -r; nvidia-smi -L"}'
```

Then the real test, in chat: ask something that forces a tool call ("list the
files in the working directory and tell me the GPU"). If the model never calls
a tool, the problem is the model/template, not the terminal.

## Security notes

- The bearer key **is** a shell as `open-terminal`. Bare metal is not a sandbox:
  that user reads anything world-readable and can disturb the host (kill
  llama-server, fill `/var`). Treat the key like a password.
- `--host 127.0.0.1` is explicit in `ExecStart`: without it open-terminal binds
  `0.0.0.0`.
- `PrivateDevices` is deliberately not set, so `nvidia-smi` works inside a
  terminal. Anything the agent starts on a port stays unreachable from the LAN
  (the firewall allows only 22 3000 4242 8001 8888 8081 9292).
- Access control per Open WebUI user/group lives on the connection row.
- Multi-user mode stays off (`OPEN_TERMINAL_MULTI_USER` unset): all users of
  that connection share one workspace.

## Tool-count warning

The OpenAPI import is about 40 tool schemas added to every chat that selects
this terminal. On a 27B model that is a lot of prompt and a lot of choices. If
calls misfire, prune in Admin -> Tools (each imported tool is listed and can be
disabled individually) and keep the large-context model entry.

## Version notes

- nixpkgs tracks open-terminal slowly: 0.14.8 at nixos-unstable head while
  upstream is 0.17.x.
- 0.15+ adds Browser / Linux-Desktop tabs (needs Chromium and a virtual
  display); 0.17.0+ adds chat with Codex, Claude Code, OpenCode, Gemini CLI and
  **Pi** through Open WebUI, which also needs an open-webui with agent support
  (0.13.x). None of that exists in 0.14.8, and none of it needs a GPU.
- Bump only this input: `nix flake update llmNixpkgs`, then rebuild. `llama-cpp`,
  `mesa`, `open-webui`, python and the kernel stay put.

## Removal

Drop the `./open-terminal.nix` import from `hosts/donnager/default.nix`, rebuild,
delete the connection in Open WebUI, then `sudo rm -rf /var/lib/open-terminal`.
Or `nixos-rebuild --rollback --target-host donnager`.
