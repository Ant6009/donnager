{ config, pkgs, lib, ... }:
let
  # Repo copy of the Qwen chat template; writeText lifts it into the store
  # and the generated yaml references the store path (world-readable, so the
  # 'llama' service user can read it). Keep in sync with the models' needs.
  qwenTemplate = ./qwen-fixed-template.jinja;

  llamaSwapConfig = pkgs.writeText "llama-swap.yaml" ''
    # sanity: how long to wait for a model to come up
    healthCheckTimeout: 300

    macros:
      llama-server: >
        ${pkgs.llama-cpp-vulkan}/bin/llama-server
        --host 127.0.0.1 --port ''${PORT}
        -ngl 999 -fa 1 --jinja
        --cache-type-k f16 --cache-type-v f16


    models:
      Qwen3.6-27b-Q4:
        cmd: |
          ''${llama-server}
          --model /var/lib/llama/models/Qwen3.6-27B-UD-Q4_K_XL.gguf
          --chat-template-file ${qwenTemplate} 
          --spec-type draft-mtp
          --spec-draft-n-max 4
          -c 131072  
          -ub 1024 -b 2048
          --chat-template-kwargs '{"preserve_thinking": true}'
          --reasoning-preserve
        ttl: 900          # unload after 15 min idle, frees VRAM
        aliases:  [ "medium" ]  

      Qwen3.6-27b-Q5_XL:
        cmd: |
          ''${llama-server}
          --model /var/lib/llama/models/Qwen3.6-27B-UD-Q5_K_XL.gguf
          --chat-template-file ${qwenTemplate} 
          --spec-type draft-mtp
          --spec-draft-n-max 4
          -c 262144
          --chat-template-kwargs '{"preserve_thinking": true}'
          --reasoning-preserve
          --flash-attn 'on'
        ttl: 900          # unload after 15 min idle, frees VRAM
        aliases: [ "default", "chat" ]

      Qwen3.6-27b-Q6:
        cmd: |
          ''${llama-server}
          --model /var/lib/llama/models/Qwen3.6-27B-UD-Q6_K_XL.gguf
          --chat-template-file ${qwenTemplate} 
          --spec-type draft-mtp
          --spec-draft-n-max 4
          -c 131072
          --chat-template-kwargs '{"preserve_thinking": true}'
          --reasoning-preserve
          --temp 0.6 --top-p 0.95 --top-k 17
          --cache-type-k q8_0 --cache-type-v q8_0
        ttl: 900          # unload after 15 min idle, frees VRAM
        aliases: [ "Clever Qwen", "XL Dense" ]
      
      Qwen3.8-27b-Q6:
        cmd: |
          ''${llama-server}
          --model /var/lib/llama/models/Qwen3.8/Qwen3.8-27B-Q6_K.gguf
          --chat-template-file ${qwenTemplate} 
          --spec-type draft-mtp
          --spec-draft-n-max 3
          -c 200000
          --chat-template-kwargs '{"reasoning_effort":"medium"}'
          --kv-unified
          --reasoning-preserve
          --temp 0.6 --top-p 0.95 --top-k 17
          --cache-type-k q8_0 --cache-type-v q8_0
        ttl: 900          # unload after 15 min idle, frees VRAM
        aliases: [ "New Qwen", "3.8 Dense" ] 

      gemma-4-12B:
        cmd: |
          ''${llama-server}
          --model /var/lib/llama/models/gemma/gemma-4-12B-it-Q6_K_L.gguf
          # --spec-type draft-mtp
          # --spec-draft-n-max 2
          -c 262144   --parallel 2
        ttl: 900          # unload after 15 min idle, frees VRAM
        aliases: [ "Gemma 4 12B", "12B XL" ]

      gemma-4-31B:
        cmd: |
          ''${llama-server}
          --model /var/lib/llama/models/gemma/gemma-4-31B-it-Q6_K.gguf
          # --spec-type draft-mtp
          # --spec-draft-n-max 2
          --fit on
          -c 262144   --parallel 2
        ttl: 900          # unload after 15 min idle, frees VRAM
        aliases: [ "Gemma 4 31B", "big gemma" ]

      Qwen3.6-35b-A3b:
        cmd: |
          ''${llama-server}
          --model /var/lib/llama/models/Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf
          --chat-template-file ${qwenTemplate}
          --fit on
          #--n-cpu-moe 16
          --spec-type draft-mtp
          --spec-draft-n-max 2
          --chat-template-kwargs '{"preserve_thinking": true}'
          -c 64000 
        ttl: 900          # unload after 15 min idle, frees VRAM
        aliases: [ "Big MoE", "XL Sparse" ]

      laguna-s-2.1-Q4:
        cmd: |
          ''${llama-server}
          --model /var/lib/llama/models/laguna-s-2.1-Q4_K_M.gguf
          --fit on
          #--n-cpu-moe 16
          #--spec-type draft-mtp
          #--spec-draft-n-max 2
          --chat-template-kwargs '{"preserve_thinking": true}'
          -c 64000 
        ttl: 900          # unload after 15 min idle, frees VRAM
        aliases: [ "Big Laguna" ]
      
      laguna-s-2.1-Q2:
        cmd: |
          ''${llama-server}
          --model /var/lib/llama/models/Laguna-S-2.1-UD-Q2_K_XL.gguf
          --fit on
          #--n-cpu-moe 16
          #--spec-type draft-mtp
          #--spec-draft-n-max 2
          --chat-template-kwargs '{"preserve_thinking": true}'
          -c 64000 
        ttl: 900          # unload after 15 min idle, frees VRAM
        aliases: [ "Small Laguna" ]

      Ornith:
        cmd: | 
          ''${llama-server}
          --model /var/lib/llama/models/ornith-1.0-35b-Q5_K_M.gguf
          -c 131072  
          --temp 0.6 --top-p 0.95
          --reasoning-preserve
          -ngl 99
          --n-predict 4096
        ttl: 900

      # small utility model that can stay resident ALONGSIDE another:
      # groups let two models share the card if they fit together
      #embedder:
      #  cmd: ''${llama-server} --model /var/lib/llama/models/embed.gguf --embedding
  '';
in
{
  systemd.services.llama-swap = {
    description = "llama-swap model router";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    environment.AMD_VULKAN_ICD = "RADV";
    environment.XDG_CACHE_HOME = "/var/cache/llama";   # keeps the shader-cache fix

    serviceConfig = {
      User = "llama";
      Group = "llama";
      SupplementaryGroups = [ "video" "render" ];      # spawned llama-servers inherit this
      StateDirectory = "llama";
      CacheDirectory = "llama";
      WorkingDirectory = "/var/lib/llama";
      ExecStart = "${pkgs.llama-swap}/bin/llama-swap --config ${llamaSwapConfig} --listen 0.0.0.0:9292";
      Restart = "on-failure";
      RestartSec = 3;
    };
  };
  users.users.llama = {
    isSystemUser = true;
    group = "llama";
  };
  users.groups.llama = { };
}
