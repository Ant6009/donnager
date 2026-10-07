# Open WebUI voice on phones (LAN)

Goal: use voice input (STT) and voice output (TTS) in Open WebUI from a phone on the
local network.

## Why a reverse proxy (Caddy) is needed

Phone browsers (iOS Safari, Android Chrome) only expose the microphone
(`getUserMedia`) on **secure contexts**: HTTPS or localhost. Open WebUI currently
serves plain HTTP at `http://192.168.68.x:3000`, so on a phone the mic button is
dead. TTS *playback* works over plain HTTP; voice *input* does not.

Fix: Caddy in front of Open WebUI with `tls internal` (Caddy's private CA). No
public domain needed on a NATed LAN.

## Verified facts (2026-10-06)

- nixpkgs `open-webui` 0.11.x **bundles `faster-whisper`** (checked in the nixpkgs
  package definition). Open WebUI's local STT therefore works with no extra
  services and no Ollama. The current setup (`ENABLE_OLLAMA_API="False"`,
  `OPENAI_API_BASE_URL` → llama-server) is the supported "no Ollama" scenario.
- STT env vars (docs.openwebui.com, env-configuration reference):
  - `AUDIO_STT_ENGINE` — empty (default) = local Whisper (faster-whisper, int8)
  - `WHISPER_MODEL` — e.g. `tiny` / `base` / `small`
  - `WHISPER_LANGUAGE` — ISO 639-1; unset = auto-detect
  - `WHISPER_COMPUTE_TYPE` — `int8` (CPU), `float16` (CUDA)
  - `WHISPER_MODEL_DIR` — default `<DATA_DIR>/cache/whisper/models`
    → `/var/lib/open-webui/data/cache/whisper/models`
  - `WHISPER_MULTILINGUAL` — `True`/`False`
- TTS env vars:
  - `AUDIO_TTS_ENGINE` — empty (default) = no backend TTS; audio playback uses the
    browser Web Speech API or the client-side **Browser Kokoro** option
  - `AUDIO_TTS_ENGINE=openai` + `AUDIO_TTS_OPENAI_API_BASE_URL` (+ `_API_KEY`,
    `_MODEL`, `_VOICE`) → any OpenAI-compatible TTS endpoint
- NixOS `services.caddy` module: declarative `virtualHosts` with `proxyPass`,
  `extraConfig`, `openFirewall`.
- Open WebUI data lives in `/var/lib/open-webui/data` (module `WorkingDirectory`
  + preStart migration). The `dataDir` env var currently set in `openwebui.nix`
  is a no-op (the real var is `DATA_DIR`); harmless, candidate for cleanup.

## Plan

### Phase 1 — voice input

1. New `hosts/donnager/caddy.nix`:

   ```nix
   { config, pkgs, lib, ... }:
   {
     services.caddy = {
       enable = true;
       openFirewall = true;
       virtualHosts."donnager.lan" = {
         extraConfig = "tls internal";
         locations."/" = {
           proxyPass = "http://127.0.0.1:3000";
         };
       };
     };
   }
   ```

   Hostname TBD: `donnager.lan` only if the LAN DNS (AdGuard LXC at
   192.168.68.3) resolves it. Fallback: raw site address `:8443` on the box IP
   via `extraConfig` (URL becomes `https://192.168.68.x:8443/`).

   Import it in `hosts/donnager/default.nix`.

2. `openwebui.nix` environment additions:

   ```nix
   WHISPER_MODEL = "base";          # try "small" for better accuracy
   WHISPER_COMPUTE_TYPE = "int8";   # CPU is fine on this box
   # WHISPER_LANGUAGE = "en";       # or leave auto-detect
   ```

   The Whisper model downloads to
   `/var/lib/open-webui/data/cache/whisper/models` on first use (needs outbound
   internet at that moment).

3. Phone: trust Caddy's internal CA once.
   - Android: `caddy trust` (via adb) or install the CA cert manually.
   - iOS: install the CA profile on the device, then Settings > General > About
     > Certificate Trust Settings > enable full trust for the Caddy CA.
   - The CA cert is in Caddy's data dir on donnager (`/var/lib/caddy/...`);
     can be scp'd to the phone if `caddy trust` is impractical headless.

4. Result: `https://donnager.lan/` on the phone, mic button works. Desktop can
   keep using `http://<ip>:3000` unchanged.

### Phase 2 — voice output

Options, in order of effort:

1. **Browser Kokoro** (client-side Kokoro-82M in the phone browser): zero server
   changes, decent voice quality. Per-user setting in Open WebUI
   (Settings > Interface > TTS).
2. **Browser Web Speech API**: zero setup, OS voices (Apple/Google), quality
   varies.
3. **Server-side TTS**: run a small TTS server on donnager (kokoro-onnx or
   piper) and set:

   ```nix
   AUDIO_TTS_ENGINE = "openai";
   AUDIO_TTS_OPENAI_API_BASE_URL = "http://127.0.0.1:<tts-port>/v1";
   AUDIO_TTS_MODEL = "<model>";
   AUDIO_TTS_VOICE = "<voice>";
   ```

   Consistent voice, no phone CPU load; one more service to maintain.

## Open questions

- Which hostname resolves on the LAN (AdGuard `.lan` records vs raw IP:port)?
- Whisper model size: `base` (fast) vs `small` (better accuracy)?
- TTS: start with Browser Kokoro, or go straight to a server-side TTS service?
