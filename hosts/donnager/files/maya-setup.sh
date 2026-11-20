#!/bin/sh
# Pinned Project Maya setup for donnager (CMP 170HX 64 GiB, 94 GiB RAM,
# Xeon W-3235). This is docs/maya.md §4.2 with every flag spelled out, so a
# rebuild regenerates exactly what hosts/donnager/maya.nix expects: Hy4-Flash
# (Maya-M) and Qwen-3.8-Flash-Next (CYBER-FROST-3.8-PS) in ONE Maya install,
# one port (8080), one API key, models on /home.
#
# Nix installs this at /etc/maya/setup.sh. Run it as the maya user, since the
# checkout and everything it writes is maya-owned:
#
#   sudo -u maya /etc/maya/setup.sh
#
# It pulls the build shell from a copy of flake.nix + flake.lock in $HOME_DIR/flake
# whenever it is not already inside one. Neither way of reaching /etc/nixos as the
# maya user works: nix's flake fetcher refuses a git repository it does not own
# ("repository path '/etc/nixos' is not owned by current user"), and git itself
# refuses it too ("detected dubious ownership in repository at '/etc/nixos/.git'").
# Two copied files are enough - devShells.maya only uses the locked nixpkgs input -
# and a directory is a path flake, so nothing has to be owned.
#
# ~245 GB of downloads (measured: Hy4 Maya-M 131.8 GB), from Hugging Face, into
# /home/maya/models. The build itself is 20-40 minutes. Nothing here is automatic:
# read what it prints.
set -eu

# Ctrl+C has to end Maya's dashboard, not this script. The Hy4 setup ends by
# launching the model in the foreground, and the INT that stopped it killed the
# whole script too (EXIT=130) with the second model never installed. Maya's own
# python installs its own SIGINT handler, so it still stops on Ctrl+C; ignoring
# INT here lets the script carry on with the next model.
trap '' INT

FLAKE=/etc/nixos                 # donnager's checkout of this repo (its devShell is what we want)
REPO=https://github.com/mw00/project-maya.git
REV=v1.1.69                      # main at e9cb6510e092 (2026-11-20), the Hy4-Flash release line
HOME_DIR=/home/maya
SRC=$HOME_DIR/src
MODELS=$HOME_DIR/models
PORT=8080
HOST=0.0.0.0                     # reachable from rocinante; 8080 is opened in default.nix
KEY_FILE=$HOME_DIR/maya-api.key  # never in git; the key order below reuses it
FLAKE_LOCAL=$HOME_DIR/flake      # copies of $FLAKE's flake.nix + flake.lock, for its devShell only
HY4_MODEL=hy4-flash-maya-m       # Maya's own 3-bit quant: 76 GiB held in RAM+VRAM
QWEN_MODEL=cyber-frost           # peasantsmith's Q5_K/IQ4_NL GGUF: 84 GiB held
CONTEXT=""                       # empty: Maya picks the context that fits the card

mkdir -p "$HOME_DIR" "$MODELS"

# --- build shell -----------------------------------------------------------
# Compiling needs nvcc + a host compiler Maya accepts. Maya's own check for
# sm_80 wants CUDA >= 12.0 and allows CUDA 13 (maya.py's nvcc_range).
in_build_shell() {
  [ -n "${IN_NIX_SHELL:-}" ] && command -v nvcc >/dev/null 2>&1
}

# Two copied files, owned by whoever runs this: nix's flake fetcher and git both
# refuse /etc/nixos when it belongs to somebody else, and devShells.maya needs
# nothing but the pinned flake.lock.
if ! in_build_shell; then
  if [ ! -f "$FLAKE_LOCAL/flake.nix" ]; then
    mkdir -p "$FLAKE_LOCAL"
    echo "copying $FLAKE/flake.nix + flake.lock -> $FLAKE_LOCAL (for its devShell only)"
    cp "$FLAKE/flake.nix" "$FLAKE/flake.lock" "$FLAKE_LOCAL/"
  fi
  echo "entering $FLAKE_LOCAL#maya (nvcc + gcc 13 + cmake + ninja + python)"
  exec nix develop "$FLAKE_LOCAL#maya" -c "$0" "$@"
fi

nvcc --version | sed -n 's/.*release \([0-9.]*\).*/nvcc \1/p' | head -1

# --- checkout --------------------------------------------------------------
if [ ! -d "$SRC/.git" ]; then
  echo "cloning $REPO at $REV"
  git clone "$REPO" "$SRC"
  ( cd "$SRC" && git checkout "$REV" )
else
  echo "checkout exists: $( cd "$SRC" && git describe --tags 2>/dev/null || git rev-parse --short HEAD )"
  echo "  update with:  cd $SRC && git fetch && git checkout <tag>   (then ./maya.sh re-builds only what changed)"
fi

cd "$SRC"

# NixOS refuses the standalone binaries pip wheels ship: they carry a generic
# ld-linux interpreter ("NixOS cannot run dynamically linked executables
# intended for generic linux environments", the stub-ld message). Maya takes
# .venv/bin/<tool> before PATH's for cmake and ninja (maya.py's venv_tool), and
# the venv's ninja wheel is what stopped the engine configure on the first run
# here: cmake -G Ninja -DCMAKE_MAKE_PROGRAM=/home/maya/src/.venv/bin/ninja.
# Point both at the build shell's own copies, which NixOS patched.
fix_venv_tools() {
  for t in ninja cmake; do
    wheel="$SRC/.venv/bin/$t"
    real=$(command -v "$t" 2>/dev/null) || continue
    [ -e "$wheel" ] || [ -L "$wheel" ] || continue
    ln -sf "$real" "$wheel"
    echo "  $wheel -> $real (the pip wheel binary is not executable on NixOS)"
  done
}

# --- API key: never in git --------------------------------------------------
# Reuse whatever an existing Maya config carries, then the key file, then make
# one and print it once (same order as /etc/strata/setup.sh).
KEY=""
for cfg in maya-*.json; do
  if [ -f "$cfg" ]; then
    KEY=$(sed -n 's/.*"api_key": "\([^"]*\)".*/\1/p' "$cfg" | head -1)
    [ -n "$KEY" ] && break
  fi
done
if [ -z "$KEY" ] && [ -f "$KEY_FILE" ]; then
  KEY=$(cat "$KEY_FILE")
fi
if [ -z "$KEY" ]; then
  KEY=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-24)
  printf '%s' "$KEY" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  echo "generated API key (shown once): $KEY"
  echo "add it to rocinante:~/.pi/agent/auth.json as {\"maya\":{\"type\":\"api_key\",\"key\":\"...\"}}"
fi

# --- model 1: Hy4-Flash (Maya-M) -------------------------------------------
# --yes takes the recommended answers; --download-model is what actually lets
# it start the ~132 GB download; --no-start ends the setup without launching the
# dashboard (without it the setup starts Maya in the foreground and the script
# waits there - Ctrl+C then takes the script down too, EXIT=130, measured).
# Maya names the config after the setup model: hy4-flash-maya-m wrote
# maya-hy4-flash-maya-m.json, whose own model_name is "hy4-flash".
echo "=== setup: $HY4_MODEL"
hy4_setup() {
  if [ -n "$CONTEXT" ]; then
    ./maya.sh --setup --model "$HY4_MODEL" --context "$CONTEXT" \
      --models-dir "$MODELS" --host "$HOST" --port "$PORT" --api-key "$KEY" \
      --yes --download-model --no-start
  else
    ./maya.sh --setup --model "$HY4_MODEL" \
      --models-dir "$MODELS" --host "$HOST" --port "$PORT" --api-key "$KEY" \
      --yes --download-model --no-start
  fi
}

# The venv only exists after Maya's own setup has created it, so the first call
# is the one that discovers the wheel binaries and stops at the configure step.
# Maya keeps everything a stopped setup already did, so one retry continues it.
fix_venv_tools
if ! hy4_setup; then
  echo "setup stopped; relinking the build shell's ninja and cmake and trying once more"
  fix_venv_tools
  hy4_setup
fi

# --- model 2: Qwen-3.8-Flash-Next (CYBER-FROST) ----------------------------
# A second --setup writes its own maya-<model>.json beside the Hy4 one; the
# Models page and /v1/models then list both. Check `ls maya-*.json` shows both
# before trusting it (docs/maya.md §5).
echo "=== setup: $QWEN_MODEL"
./maya.sh --setup --model "$QWEN_MODEL" \
  --models-dir "$MODELS" --host "$HOST" --port "$PORT" --api-key "$KEY" \
  --yes --download-model --no-start

# --- calibrate by hand, once ------------------------------------------------
# A service start measures nothing (nobody is there to wait), so upstream says
# to run these in a terminal with Maya stopped. They load the model a few times
# and keep the answer in the config. Skip with CALIBRATE=0.
case "${CALIBRATE:-1}" in
  0) echo "CALIBRATE=0: skipped the speed calibration" ;;
  *)
    for cfg in maya-*.json; do
      if [ -f "$cfg" ]; then
        echo "=== speed calibration: $cfg (5-30 minutes, Maya must be stopped)"
        ./maya.sh --config "$cfg" --speed-calibration --no-start || \
          echo "  skipped/failed: the model still runs with the engine's defaults"
      fi
    done
    ;;
esac

# --- hand Maya's RAM and the card back when idle ----------------------------
# idle_unload_s mirrors llama-swap's 900 s preload expiry: after 15 minutes
# with nothing running or waiting the engine ends, its VRAM and its pinned RAM
# tier go back, /v1/models still lists the model as "unloaded", and the next
# request loads it again (about a minute before its first token).
case "${IDLE_UNLOAD:-1}" in
  0) echo "IDLE_UNLOAD=0: no idle unload" ;;
  *)
    python3 - "$SRC" <<'EOF'
import json, glob, os
for path in glob.glob(os.path.join(os.environ.get("SRC", "."), "maya-*.json")):
    try:
        cfg = json.load(open(path))
    except Exception as e:
        print(f"  {os.path.basename(path)}: not JSON ({e}); left alone")
        continue
    if cfg.get("idle_unload_s") == 900:
        continue
    cfg["idle_unload_s"] = 900
    json.dump(cfg, open(path, "w"), indent=2)
    print(f"  {os.path.basename(path)}: idle_unload_s = 900")
EOF
    echo "  note: a new --setup rewrites the config; re-run this script to add it back"
    ;;
esac

# --- verify, don't assume ---------------------------------------------------
echo "--- configs Maya wrote (these are the unit's startConfig candidates) ---"
ls -1 "$SRC"/maya-*.json 2>/dev/null || echo "none: the setup did not finish"

echo "--- what each config is sized for ---"
for cfg in "$SRC"/maya-*.json; do
  [ -f "$cfg" ] || continue
  echo "  $(basename "$cfg")"
  grep -E -- '"model_name"|"host"|"port"|"max-context"|"idle_unload_s"' "$cfg" | sed 's/^/    /'
done

cat <<EOF
next steps
  cd $SRC && ./maya.sh --config maya-hy4-flash-maya-m.json   # start it by hand first, watch the load lines
  curl -s -H "Authorization: Bearer \$KEY" http://127.0.0.1:$PORT/v1/models
  ls -l $MODELS                                               # Hy4 Maya-M ~141G, CYBER-FROST ~113G
  nvidia-smi --query-gpu=memory.used,memory.free --format=csv
  free -g                                                     # Maya pins nearly all of it while loaded
  then flip services.maya.enable = true (and services.strata.enable = false) and rebuild
EOF
