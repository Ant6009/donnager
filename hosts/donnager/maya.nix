# Project Maya (Hy4-Flash + Qwen-3.8-Flash-Next) as a systemd service.
#
# Like strata, the engine, its venv and its models live OUT of the Nix tree in
# /home/maya (one-time clone + build, docs/maya.md §4.2); only this unit, the
# pinned setup script and the directories are Nix-managed. Disabled by default:
# flip services.maya.enable only after the out-of-tree setup in docs/maya.md
# §4.2 has run by hand and one completion has been eyeballed.
#
# "One engine, two models" (docs/maya.md §1): Maya runs Hy4-Flash on its own
# engine (maya-hy4) and Qwen-3.8-Flash-Next on the maya engine, both from one
# install on one port, so switching between them is a model name, not a
# service. Port 8080 on 0.0.0.0 (opened in default.nix). strata (8081) and
# llama-swap (9292) stay configured as the fallback path for Qwen.
#
# Three separate module contributions, not one attrset merged with //. Reading
# config.services.maya (this module's own option) while building the returned
# config is a cycle: `optionalAttrs cfg.enable` fails with "infinite recursion
# encountered" while `mkIf cfg.enable` does not, because mkIf hands the condition
# to the module system unevaluated. And `A // lib.mkIf ...` puts _type /
# condition / content into A, which makes the module system use only mkIf's
# `content` and drop A. Both were caught with
#   nix eval .#nixosConfigurations.donnager.config.users.users
let
  options = { lib, ... }: {
    options.services.maya = {
      enable = lib.mkEnableOption "Project Maya (Hy4-Flash + Qwen-3.8-Flash-Next, port 8080)";

      srcDir = lib.mkOption {
        type = lib.types.str;
        default = "/home/maya/src";
        description = "Maya's checkout; built out-of-tree by /etc/maya/setup.sh.";
      };

      modelsDir = lib.mkOption {
        type = lib.types.str;
        default = "/home/maya/models";
        # / is 841G with ~267G free, /home (nvme0n1p4, the same NVMe) has ~724G.
        # Hy4-Flash Maya-M is ~141G (model 68.4 + n-gram table 63.4 + MTP 7.5 +
        # drafter 0.9 + vision 0.8) and CYBER-FROST ~113G, so the models cannot
        # sit beside the OS.
        description = "Maya's --models-dir. Must be on /home (nvme0n1p4): the two model sets are ~254G.";
      };

      startConfig = lib.mkOption {
        type = lib.types.str;
        default = "maya-hy4-flash.json";
        description = ''
          Which per-model config the unit boots with. Maya names them
          maya-<model>.json, so check what the setup actually wrote before
          flipping services.maya.enable: ls /home/maya/src/maya-*.json
        '';
      };
    };
  };

  # The account, the model directory and the pinned setup script are NOT behind
  # services.maya.enable: §4.2 has to run before the engine exists, and it must
  # run as the maya user into a maya-owned directory. So `enable = false` adds a
  # user, two directories and one file, starts nothing, and leaves strata alone.
  infrastructure = { config, lib, ... }:
    let cfg = config.services.maya; in {
      config = {
        users.users.maya = {
          isSystemUser = true;
          group = "maya";
          home = "/home/maya";
        };
        users.groups.maya = { };

        # Created at activation, so the maya user has a writable HOME and a
        # models directory before the setup script is ever run.
        systemd.tmpfiles.rules = [
          "d /home/maya 0750 maya maya -"
          "d ${cfg.modelsDir} 0750 maya maya -"
        ];

        # The pinned setup command as an executable the rebuild carries,
        # mirroring /etc/strata/setup.sh:
        #   sudo -u maya /etc/maya/setup.sh
        environment.etc."maya/setup.sh" = {
          source = ./files/maya-setup.sh;
          mode = "0755";
        };

        # (The build shell is not installed here: the setup script clones this
        # repo into /home/maya/flake for its own `nix develop`, because nix's
        # flake fetcher refuses a git repository it does not own and /etc/nixos
        # is antoine's. An attempt to hand out flake.nix via environment.etc is
        # what measured that - every form of it, .source and .text, lands as a
        # symlink into /etc/static, which is dangling inside the store copy nix
        # makes of any flake directory.)
      };
    };

  service = { config, lib, ... }:
    let cfg = config.services.maya; in
    lib.mkIf cfg.enable {
      systemd.services.maya = {
        description = "Project Maya inference engine (Hy4-Flash / Qwen-3.8-Flash-Next, port 8080)";
        # The boot slot stays a single switch, the way llama-swap's already is
        # (hosts/donnager/llama-swap.nix gates its wantedBy the same way):
        # services.strata.enable = true owns the boot, false hands it to Maya.
        # services.maya.enable alone only *installs* the unit, so it is safe to
        # turn on before §4.2 has run. Moving to Maya afterwards is one flag, or
        # no rebuild at all: `systemctl start maya` stops strata.
        wantedBy = lib.mkIf (!config.services.strata.enable) [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        # One big model per card and per RAM pool. Maya pins "most of the free
        # RAM (all but about 6 GB)" for its expert tier, and strata alone is
        # 56.4 GiB RSS plus a 26.8 GiB PLE table of 94 GiB (docs/strata.md
        # §4.5), so these three never run together. Conflicts= both ways means
        # `systemctl start strata` hands the card and the RAM over instead of
        # OOMing the box.
        conflicts = [ "strata.service" "llama-swap.service" ];

        unitConfig = {
          # services.maya.enable = true is not the flag that says "§4.2 has run",
          # so the unit has to survive being enabled on a box with no checkout:
          # without this condition maya.sh is missing, ExecStart fails, and
          # Restart=on-failure re-fails every 30 s forever.
          #
          # Measured on donnager 2026-11-20 (§4.4): the condition does skip the
          # unit cleanly - journal "skipped, unmet condition check
          # ConditionPathExists=/home/maya/src/maya.sh", Result=success, no
          # restart attempts. It does NOT stop Conflicts= from firing: `systemctl
          # start maya` still took strata down (back up 5 s later). Starting Maya
          # before §4.2 has run is therefore harmless but pointless, and it costs
          # strata.
          ConditionPathExists = "${cfg.srcDir}/maya.sh";
        };

        serviceConfig = {
          User = "maya";
          Group = "maya";
          SupplementaryGroups = [ "video" "render" ];
          WorkingDirectory = cfg.srcDir;

          Environment = [
            # The maya account's home has to be writable: Maya keeps its measured
            # drive-read settings in ~/.config/project-maya/drive-reads.txt, and
            # a system user's default home (/var/empty) is not.
            "HOME=/home/maya"

            # Same trap as strata (hosts/donnager/strata.nix): the engine binary
            # carries a RUNPATH into the CUDA toolkit's lib/stubs, i.e. a STUB
            # libcuda, and dies with "CUDA driver is a stub library". An
            # inherited LD_LIBRARY_PATH beats the RUNPATH.
            "LD_LIBRARY_PATH=/run/opengl-driver/lib"
          ];

          # Port, host and API key are NOT here: they live in the config the
          # pinned setup script wrote (docs/maya.md §4.2). This is upstream's own
          # systemd shape (project-maya docs/SETUP.md, "Running Maya as a systemd
          # service"): maya.sh --config maya-<model>.json.
          ExecStart = "${cfg.srcDir}/maya.sh --config ${cfg.srcDir}/${cfg.startConfig}";

          # A 220B model at a long context takes minutes to come up (it pins its
          # expert tier in RAM and warms its caches) and minutes to save its
          # conversations and give the GPUs back. systemd must not kill either,
          # or a slow start loads it again forever.
          TimeoutStartSec = 3600;
          TimeoutStopSec = 600;

          # Maya's expert tier is pinned RAM; the strata unit already needs this
          # for its PLE table. Re-measure before trusting it (docs/maya.md §5).
          LimitMEMLOCK = "infinity";

          Restart = "on-failure";
          RestartSec = 30;
        };
      };
    };
in
{
  imports = [ options infrastructure service ];
}
