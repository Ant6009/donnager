# Strata (Qwen3.8-Flash-Next) as a systemd service.
#
# The engine, venv and model live OUT of the Nix tree in /var/lib/strata
# (one-time build, see docs/strata.md §4.2) — only this unit is
# Nix-managed. Disabled by default: enable only after the out-of-tree
# build is verified by hand (run the generated run script directly,
# strata_bench.py, eyeball a completion).
#
# Port 8081 on 127.0.0.1 (no firewall change). Open WebUI gets a second
# provider at http://127.0.0.1:8081/v1; llama-swap stays on 9292.
{ config, pkgs, lib, ... }:
let
  cfg = config.services.strata;
in
{
  options.services.strata.enable =
    lib.mkEnableOption "the Strata inference engine (Qwen3.8-Flash-Next, port 8081)";

  config = lib.mkIf cfg.enable {
    systemd.services.strata = {
      description = "Strata inference engine (Qwen3.8-Flash-Next, port 8081)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];

      serviceConfig = {
        User = "strata";
        Group = "strata";
        SupplementaryGroups = [ "video" "render" ];
        WorkingDirectory = "/var/lib/strata/src";

        # From the generated run-iq3_xxs.sh (minus --open, which pops a
        # browser — headless here). The config carries the engine args,
        # model paths, MTP, port and lib_dirs (CUDA 13.0 from the store).
        ExecStart = "/var/lib/strata/src/.venv/bin/python /var/lib/strata/src/serve/server.py --engine strata --config /var/lib/strata/src/strata-iq3_xxs.json --port 8081";

        Environment = [
          # --- Stage 1: bit-exact, PR #3779 set (measured on a CMP 170HX) ---
          "STRATA_GRAPH_PRIO=1"     # decode +1.8 %
          "STRATA_MMVQ_IL_PF=1"     # decode +1.4 %
          "STRATA_MMVQ_IL_SM80=0"   # decode +2.7..3.2 %
          "STRATA_CKPT_ASYNC=1"     # conversation cache: background copies
          "STRATA_PARK_ASYNC=1"     # conversation cache: async park
          "STRATA_CKPT_GATHER=1"    # conversation cache: gather
          # TODO(runbook): values for these three:
          # "STRATA_CKPT_VRAM_SLOTS=*"
          # "STRATA_CKPT_POOL=*"
          # "STRATA_PARK_VRAM_MIB=*"
          # TODO(runbook): AVX2 CPU switch — exact name:
          # "STRATA_*=*"
          # --- Stage 2: prompt-path tensor cores — enable only after the
          # --- stage-1 baseline is recorded (strata_bench.py output saved) ---
          # "STRATA_PF_FUSED_F16=1"  # prompts +2..6 % (NOT bit-exact)
          # "STRATA_PF_FUSED_WS=1"
          # "STRATA_GDN_TC=1"        # DeltaNet scan: prompts +6.6..7.6 %
        ];

        Restart = "on-failure";
        RestartSec = 5;

        # RAM, not VRAM, is the tight resource (~71-80 GB committed of 96);
        # parked conversation KV and the ~29 GB PLE table land in system
        # RAM. Cap the unit so a leak cannot swap the box.
        # TODO(runbook): final value per the RAM guidance:
        # MemoryMax = "40G";
      };
    };

    users.users.strata = {
      isSystemUser = true;
      group = "strata";
    };
    users.groups.strata = { };
  };
}
