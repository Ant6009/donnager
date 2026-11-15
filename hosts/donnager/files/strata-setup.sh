#!/bin/sh
# Pinned Strata setup for donnager (CMP 170HX, 64 GiB). This is docs/strata.md
# §4.2's command with every flag spelled out, so a rebuild regenerates the
# same service the NixOS unit expects: 256K context, int8 KV, port 8081,
# LAN listen, the same API key, local GGUFs, pictures on the GPU, no browser,
# no auto-start.
#
# Nix installs this at /etc/strata/setup.sh (see hosts/donnager/strata.nix).
# Run it as the strata user, since the checkout and everything it writes is
# strata-owned:
#
#   sudo -u strata /etc/strata/setup.sh              # reuse the built engine
#   sudo -u strata /etc/strata/setup.sh --build      # recompile for sm_80
#
# If the compile needs a privileged nix build, run the --build form as root
# and finish with: sudo chown -R strata:strata /var/lib/strata/src
#
# Then: sudo systemctl stop llama-swap && sudo systemctl restart strata
set -eu

# The strata account's home is /var/empty (not writable), so uv/pip/nvidia
# caches need a HOME the service user can actually write to.
export HOME=/var/lib/strata

SRC=/var/lib/strata/src
CFG="$SRC/strata-iq3_xxs.json"
RUN="$SRC/run-iq3_xxs.sh"
GGUF_DIR=/var/lib/llama/models/Qwen3.8flash
KEY_FILE=/var/lib/strata/strata-api.key

CONTEXT=262144   # the model's trained context; pi's window is sized from this
KV=int8          # 256K of KV is ~5 GB parked in RAM at int8, not 20 GB at fp16
PORT=8081
HOST=0.0.0.0     # reachable from rocinante (8081 is opened in default.nix)

cd "$SRC"

# Pictures need two things setup.py will not fetch for us on this box.
#
# 1. The picture reader is a second binary (engine/strata-vision, llama.cpp's
#    mtmd). Without it setup prints "this engine has no image encoder: images
#    off" and quietly stays text-only, so --vision gpu needs --build. Since
#    the engine's own source is unchanged, only tools/vision compiles (10-20
#    minutes, once).
# 2. With --gguf-dir, setup downloads nothing: it wants the pinned mmproj in
#    that folder under its pinned name. The folder is root-owned, so it goes
#    in by hand (docs/strata.md §4.2). Unsloth's mmproj-F16.gguf beside the
#    llama-swap shards is a different file (904,004,000 bytes); renaming it
#    fails the size check.
MMPROJ=mmproj-Qwen3.8-Flash-Next-BF16.gguf
MMPROJ_URL=https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF/resolve/ed59f92082b1e93c0e96d60a8b11aab089b52f09/$MMPROJ
case " $* " in
  *" --vision no "*|*" --vision none "*|*" --vision off "*) ;;   # images asked off
  *)
    if [ ! -e "$SRC/engine/strata-vision" ]; then
      case " $* " in
        *" --build "*) ;;
        *) echo "note: engine/strata-vision is missing; without --build setup turns images off" ;;
      esac
    fi
    if [ ! -f "$GGUF_DIR/$MMPROJ" ]; then
      echo "$MMPROJ is missing from $GGUF_DIR (--gguf-dir means no download):"
      echo "  sudo curl -L -o $GGUF_DIR/$MMPROJ $MMPROJ_URL"
      echo "  907,543,008 bytes, sha256 b1a82259702816a5330d7bd7607cd9676b11780e79ff7348c21103ff3ce49bd0"
      exit 1
    fi
    ;;
esac

# --build: compile the engine for sm_80 instead of taking the prebuilt one.
# That needs the repo's own dev shell (CUDA 13.0, cmake, ninja, python); pull
# it in when we are not already inside one.
case " $* " in
  *" --build "*)
    if [ -z "${IN_NIX_SHELL:-}" ]; then
      exec nix develop -c "$0" "$@"
    fi
    ;;
esac

# The API key is deliberately not in git. Reuse whatever the existing config
# carries (that is the key pi already knows, rocinante:~/.pi/agent/auth.json),
# then the key file, then make one and print it once.
KEY=""
if [ -f "$CFG" ]; then
  KEY=$(sed -n 's/.*"api_key": "\([^"]*\)".*/\1/p' "$CFG" | head -1)
fi
if [ -z "$KEY" ] && [ -f "$KEY_FILE" ]; then
  KEY=$(cat "$KEY_FILE")
fi
if [ -z "$KEY" ]; then
  KEY=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-24)
  printf '%s' "$KEY" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  echo "generated API key (shown once): $KEY"
  echo "add it to rocinante:~/.pi/agent/auth.json as {\"strata\":{\"type\":\"api_key\",\"key\":\"...\"}}"
fi

./setup.sh --yes \
  --family qwen --model IQ3_XXS \
  --context "$CONTEXT" --kv "$KV" \
  --vision gpu --mtp on \
  --host "$HOST" --port "$PORT" \
  --api-key "$KEY" \
  --gguf-dir "$GGUF_DIR" \
  --no-browser --no-start \
  "$@"

# setup.py picks the engine args itself; check the two that the unit and the
# clients are sized for, and fail loudly rather than booting something smaller.
if [ -f "$CFG" ]; then
  echo "--- generated engine args ---"
  grep -E -- '"--max-context"|"--kv"|"model_name"|"port"|"host"' "$CFG"
  grep -A1 -- '"--max-context"' "$CFG" | grep -q "$CONTEXT" || {
    echo "setup wrote a context other than $CONTEXT — do not start the unit with it"
    exit 1
  }
fi

# The generated launcher ends with --open (pops a browser). The unit does not
# use this file, but a human running it by hand on a headless box does.
if [ -f "$RUN" ] && grep -q -- '--open' "$RUN"; then
  sed -i 's/ "--open"//; s/ --open//' "$RUN"
  echo "stripped --open from $(basename "$RUN")"
fi

cat <<'EOF'
next steps
  ls -l /var/lib/strata/src/engine/strata-vision   # the picture reader (--build built it)
  grep -E -- '"--vision"|"vision"' /var/lib/strata/src/strata-iq3_xxs.json
  sudo systemctl stop llama-swap        # one backend per card: strata fills the VRAM
  sudo systemctl restart strata
  nvidia-smi --query-gpu=memory.used,memory.free --format=csv   # the GPU reader keeps ~1.4 GiB + 700 MiB of reserve
  systemctl show strata -p LimitMEMLOCK # infinity: the 26.8 GiB PLE table stays locked
  journalctl -u strata -b | grep 'VRAM free'
EOF
