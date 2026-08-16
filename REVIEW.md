# Config review — donnager (Mac Pro 7,1 inference server)

Date: 2026-08-16 · Scope: full repo review (all files read, flake force-evaluated)
Legend: 🔴 blocking · 🟠 security · 🟡 hygiene · ✅ fixed · ℹ️ no action needed

---

## 🔴 1. t2fanrd build failure — crates.io 403 (BLOCKS `nixos-rebuild`)

Enabling `services.t2fanrd` (see #2) pulls the `t2fanrd 0.1.0` package from the
**T2FanRD flake** (`github:GnomedDev/T2FanRD`), which builds it from source with
`cargoHash` vendoring. The vendor step downloads crate tarballs and gets:

```
Exception: Failed to fetch file from
https://crates.io/api/v1/crates/getrandom/0.2.12/download. Status code: 403
```

**Root cause:** in `flake.lock`, the `t2fanrd` input's `nixpkgs` is locked to
**2025-08-03** (`5b09dc45…`, no `follows`). That old nixpkgs ships a
`fetch-cargo-vendor-util` that downloads from the `crates.io/api/v1/…/download`
endpoint, which Fastly/crates.io 403s (rate-limits / deprecates) for many IPs.
Current nixpkgs uses the `static.crates.io` CDN endpoint instead, which is
reliable.

**Fix (preferred):** make t2fanrd follow the root nixpkgs in `flake.nix`:

```nix
t2fanrd = {
  url = "github:GnomedDev/T2FanRD";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

then `nix flake update t2fanrd` (or let the first build re-lock). Side effect:
t2fanrd rebuilds with the current rustc — it's a small package, no problem.

**Fix (alternative):** plain retry — if the 403 was transient rate-limiting the
old endpoint may work once. Less reliable.

Note: `t2fanrd` is **not** a nixpkgs package (verified via search.nixos.org —
no such package); it only exists via the T2FanRD flake, so the flake input is
the only lever.

---

## ✅ 2. t2fanrd fan curves were dead code — FIXED (deploy blocked by #1)

`hosts/macpro/t2fanrd.nix` (Fan1–4, 40→65 °C exponential) was never imported,
so effective config was `services.t2fanrd.enable = false`. The Vega II is
**passively cooled** — case fans (T2-controlled) are the only cooling, and with
t2fanrd off the stock T2 firmware curve (tuned for silence, conservative under
sustained load) was the only fan management. Live check on the box confirmed
only the `lact` daemon was running.

Fix applied: `./t2fanrd.nix` added to imports in `hosts/macpro/default.nix`.
Verified by eval: `services.t2fanrd.enable = true`, Fan1 = `{low_temp=40,
high_temp=65, speed_curve="exponential"}`.

## ✅ 3. LACT removed — FIXED

`services.lact.enable = true` in `gpu.nix` was a no-op for cooling (LACT drives
*GPU* fans; this card has none) and it's a GUI app on a headless box. Removed.

---

## 🟠 4. Searxng secret key is a literal placeholder

`hosts/macpro/searx.nix`: `server.secret_key = "@SEARXNG_SECRET@"` — the
placeholder string is the actual effective value (verified by eval), committed
to GitHub. Generate a real random secret and keep it out of the repo
(sops/agenix/loreke, or at minimum an `environmentFile` / untracked file).

## 🟠 5. Firewall wider than needed (decision required)

Effective `allowedTCPPorts = [22 3000 8001 8080 8888 9292]` (verified by eval):

| Port | Service | Bind | Issue |
|------|---------|------|-------|
| 8001 | mcp-nixos | 0.0.0.0 | executes nix commands, **no auth** — biggest exposure |
| 9292 | llama-swap | 0.0.0.0 | unauthenticated model inference |
| 8888 | searxng | 0.0.0.0 | only open-webui needs it, via 127.0.0.1 |
| 8080 | — | — | nothing listens (leftover from dead `llama.nix`) |

If trusted LAN: acceptable. Otherwise bind 8001/9292/8888 to `127.0.0.1`
(`httpHost`, `--listen`, uwsgi `http`) and shrink firewall to `[22 3000]`.

---

## 🟡 6. Root `configuration.nix` is dead — delete

The flake only imports `hosts/macpro/default.nix`. The root file (leftover
`nixos-generate-config` template, contains commented `hostName = "donager"`
typo and a conflicting `stateVersion = "26.11"`) is never evaluated and will
mislead the next editor. `hardware-configuration.nix`'s "edit
configuration.nix instead" header points at this dead file.

## 🟡 7. `hosts/macpro/llama.nix` is dead *and* broken — delete or finish

Commented out of imports, and its `systemd.services.llama-server` has **no
`ExecStart`** — enabling it would fail. Superseded by `llama-swap.nix`.

## 🟡 8. `result` symlink is committed

Machine-specific `/nix/store` symlink tracked in git. `git rm --cached result`
+ add `result` to `.gitignore`.

## 🟡 9. Naming split: `macpro` vs `donnager` (decision required)

Flake key + host dir are `macpro` (`--flake .#macpro`), hostname is `donnager`.
Works, but renaming key/dir to `donnager` removes a footgun (result symlink
becomes `nixos-system-donnager-…`).

## 🟡 10. `nixos-hardware` floats on Jan-2026 nixpkgs (verify intent)

`flake.lock`: the `nixos-hardware` input's nixpkgs is a **2026-01-09**
`26.05pre` channel tarball (no `inputs.nixpkgs.follows = "nixpkgs"` in
`flake.nix`) — ~7 months older than the system nixpkgs. The `apple-t2` module
sets `boot.kernelPackages` (your **T2-patched kernel**), so kernel vs
userspace come from different nixpkgs. If this is deliberate (soopy.moe's
binary cache is keyed to a specific nixpkgs — the flake comment says the cache
saves ~1h of T2 kernel compilation), add a comment saying so. Otherwise add
the `follows` and expect one T2 kernel rebuild/cache-miss.

---

## 🟡 11. `modules/git/default.nix` — two typos + not imported

- `user.user.antoine` → should be `users.users.antoine`
- `pakgs.git` → `pkgs.git`

Not imported anywhere, so the build passes — but it explodes when imported,
and until then the declarative git identity doesn't exist (manual
`git config --global` on the box is carrying it). Fix typos, import from
`hosts/macpro/default.nix`, and it matches the manual config already in place.

## 🟡 12. Qwen chat template not wired up

`llama-swap.nix` references `/var/lib/llama/models/chat_template.jinja`
(runtime path), but the repo's `hosts/macpro/qwen-fixed-template.jinja` is
never copied there. If the file is missing on the server, **every Qwen model
fails to start**. Wire it: e.g. install the repo file into the store and copy
it in an `ExecStartPre`/activation, or reference the repo path directly in the
llama-swap config. (Verify the file currently exists on the box — if it does,
this is a reproducibility gap, not a live breakage.)

---

## ℹ️ No action needed

- `openwebui.nix`: `dataDir` sits inside `environment` — it's a NixOS option
  (`services.open-webui.dataDir`), not an env var. Harmless (default is the
  same path) but misplaced if you ever change it.
- `security.sudo.wheelNeedsPassword = false` — deliberate per inline comment.
- `system.stateVersion = "25.11"` — correct (install version, not nixpkgs
  version). Do not "fix" to match nixpkgs.
- Substituters verified correct: both `cache.soopy.moe` and `cache.nixos.org`
  present in effective config.

## Verified good

- SSH hardening: `PasswordAuthentication = false`, `PermitRootLogin = "no"`.
- `.gitignore` excludes `*.gguf` / `*.log` (models stay out of git).
- `modules/mcp-servers/default.nix` is well-built: per-server firewall option,
  service hardening (NoNewPrivileges, ProtectSystem=strict, ProtectHome).
- llama-swap design (TTL unloading, aliases, per-model contexts) is solid.
- Flake evaluates cleanly; all services resolve (`mcp-nixos`, `open-webui`,
  `searx`, `llama-swap` enabled).
