{ config, pkgs, lib, ... }:
let
  # froggeric's fixed Qwen chat template, fetched from the canonical HF repo.
  # Pinned to a commit + content hash: reproducible builds, and upgrading is
  # an explicit sha+hash bump (a silent upstream change would fail the hash).
  # v22.1 is the qwen3.8 template — matches the Qwen3.8 models below and the
  # reasoning_effort / preserve_reasoning kwargs passed per-model.
  qwenTemplate = pkgs.fetchurl {
    url = "https://huggingface.co/froggeric/Qwen-Fixed-Chat-Templates/resolve/2b50d8ef73e9ba606680856aaeb46ab94702e788/chat_template.jinja";
    hash = "sha256-5NSVVCBkXxpl+4n8Gk7Wdv7nzYIU52o/UgyMjzN4Tac=";
    name = "qwen-froggeric-chat-template-v22.1.jinja";
  };

  llamaSwapConfig = pkgs.writeText "llama-swap.yaml" ''
    # sanity: how long to wait for a model to come up
    healthCheckTimeout: 300

    macros:
      llama-server: >
        ${pkgs.llama-cpp-cuda}/bin/llama-server
        --host 127.0.0.1 --port ''${PORT}
        --jinja
        --cache-type-k q8_0 --cache-type-v q8_0


    models:
      
      Qwen3.8-27b-UD-Q6_K_M:
        cmd: |
          ''${llama-server}
          --model /var/lib/llama/models/Qwen3.8/Qwen3.8-27B-UD-Q6_K_M.gguf
          --chat-template-file ${qwenTemplate} 
          --device "CUDA0"
          -t 12
          --spec-type draft-mtp
          --spec-draft-n-max 8
          --spec-draft-p-min 0.8
          -ub 1024
          --cache-reuse 256
          -np 1
          -fa on
          -c 262144
          --metrics
          --chat-template-kwargs '{"reasoning_effort":"medium"}'
          --kv-unified
          --reasoning-preserve
          --temp 0.8 --top-p 0.95 --top-k 20
        ttl: 900          # unload after 15 min idle, frees VRAM
        aliases: [ "New Qwen", "3.8 Dense" ] 

      Qwen3.8-27b-UD-Q6_K_M Vision:
        cmd: |
          ''${llama-server}
          --model /var/lib/llama/models/Qwen3.8/Qwen3.8-27B-UD-Q6_K_M.gguf
          --mmproj /var/lib/llama/models/Qwen3.8/mmproj-F16.gguf
          --device "CUDA0"
          --chat-template-file ${qwenTemplate} 
          -t 12
          --spec-type draft-mtp
          --spec-draft-n-max 8
          --spec-draft-p-min 0.8
          -ub 1024
          --cache-reuse 256
          -np 1
          -fa on
          -c 262144
          --metrics
          --chat-template-kwargs '{"reasoning_effort":"medium"}'
          --kv-unified
          --reasoning-preserve
          --temp 0.8 --top-p 0.95 --top-k 20
        ttl: 900          # unload after 15 min idle, frees VRAM
        aliases: [ "Vision Qwen", "3.8 Dense Vision" ] 

      Qwen3.8-Flash-UD-Q4_K_XL:
        cmd: |
          ''${llama-server}
          --model /var/lib/llama/models/Qwen3.8flash/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf
          --chat-template-file ${qwenTemplate} 
          --device "CUDA0"
          --load-mode none
          --fit on
          --fit-target 256
          -t 20
          -tb 24
          #--spec-type draft-mtp
          #--spec-draft-model /var/lib/llama/models/Qwen3.8flash/MTP/mtp-Qwen3.8-Flash-Next-shared-Q4_K_M.gguf
          #--spec-draft-n-max 3
          #--spec-draft-p-min 0.75
          -ub 512
          -np 1
          -fa on
          -c 131072
          --chat-template-kwargs '{"reasoning_effort":"medium"}'
          --kv-unified
          --reasoning-preserve
          --temp 1 --min-p 0.0  --top-p 0.95 --top-k 20
          
        ttl: 900
        aliases: [ "Flash", "3.8 Flash" ]

      Qwen3.8-Flash-UD-Q4_K_XL Vision:
        cmd: |
          ''${llama-server}
          --model /var/lib/llama/models/Qwen3.8flash/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf
          --mmproj /var/lib/llama/models/Qwen3.8flash/mmproj-F16.gguf
          --chat-template-file ${qwenTemplate} 
          --device "CUDA0"
          -t 12
          #--spec-type draft-mtp
          #--spec-draft-model /var/lib/llama/models/Qwen3.8flash/MTP/mtp-Qwen3.8-Flash-Next-shared-Q4_K_M.gguf
          #--spec-draft-n-max 3
          #--spec-draft-p-min 0.75
          -ub 512
          -np 1
          -fa on
          -c 131072
          --chat-template-kwargs '{"reasoning_effort":"medium"}'
          --kv-unified
          --reasoning-preserve
          --temp 0.8 --top-p 0.95 --top-k 20
        ttl: 900
        aliases: [ "Flash Vision" ]

      # 180B MoE (~6B active), UD-Q4_K_XL ~104G: splits across 64G VRAM + RAM,
      # llama.cpp auto-offloads the MoE experts that don't fit on the card.
      Qwen3.8-Flash-UD-Q4_K_XL:
        cmd: |
          ''${llama-server}
          --model /var/lib/llama/models/Qwen3.8flash/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf
          --chat-template-file ${qwenTemplate} 
          --device "CUDA0"
          -t 12
          --spec-type draft-mtp
          --spec-draft-model /var/lib/llama/models/Qwen3.8flash/MTP/mtp-Qwen3.8-Flash-Next-shared-Q4_K_M.gguf
          --spec-draft-n-max 3
          --spec-draft-p-min 0.75
          -ub 512
          -np 1
          -fa on
          -c 131072
          --chat-template-kwargs '{"reasoning_effort":"medium"}'
          --kv-unified
          --reasoning-preserve
          --temp 0.8 --top-p 0.95 --top-k 20
        ttl: 900
        aliases: [ "Flash", "3.8 Flash" ]

      Qwen3.8-Flash-UD-Q4_K_XL Vision:
        cmd: |
          ''${llama-server}
          --model /var/lib/llama/models/Qwen3.8flash/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf
          --mmproj /var/lib/llama/models/Qwen3.8flash/mmproj-F16.gguf
          --chat-template-file ${qwenTemplate} 
          --device "CUDA0"
          -t 12
          --spec-type draft-mtp
          --spec-draft-model /var/lib/llama/models/Qwen3.8flash/MTP/mtp-Qwen3.8-Flash-Next-shared-Q4_K_M.gguf
          --spec-draft-n-max 3
          --spec-draft-p-min 0.75
          -ub 512
          -np 1
          -fa on
          -c 131072
          --chat-template-kwargs '{"reasoning_effort":"medium"}'
          --kv-unified
          --reasoning-preserve
          --temp 0.8 --top-p 0.95 --top-k 20
        ttl: 900
        aliases: [ "Flash Vision" ]

      Ornith:
        cmd: | 
          ''${llama-server}
          --model /var/lib/llama/models/Ornith-1.5-35B-Q5_K_M.gguf
          --mmproj /var/lib/llama/models/mmproj-Ornith-1.5-35B-BF16.gguf 
          --chat-template-file ${qwenTemplate} 
          --device "CUDA0"
          -c 262144  
          --kv-unified
          --temp 0.6 --top-p 0.95
          --reasoning-preserve
          -ngl 99
          --n-predict 2048
          --image-min-tokens 1024
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

    #environment.AMD_VULKAN_ICD = "RADV";
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
