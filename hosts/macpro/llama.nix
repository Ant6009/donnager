{
  config,
  pkgs,
  lib,
  ...
}: {
  # Put GGUFs in /var/lib/llama/models  (StateDirectory creates & owns it).
  systemd.services.llama-server = {
    description = "llama.cpp server (Vulkan/RADV)";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target"];
    wants = ["network-online.target"];

    environment.AMD_VULKAN_ICD = "RADV";
    environment.XDG_CACHE_HOME = "/var/cache/llama";

    serviceConfig = {
      # CRITICAL for a headless service: give it access to the DRI render node.
      DynamicUser = false;
      User = "llama";
      Group = "llama";
      SupplementaryGroups = ["video" "render"];
      StateDirectory = "llama";
      WorkingDirectory = "/var/lib/llama";
      CacheDirectory = "llama";

      Restart = "on-failure";
      RestartSec = 3;
    };
  };

  users.users.llama = {
    isSystemUser = true;
    group = "llama";
  };
  users.groups.llama = {};

  # ---- Declarative alternative (comment the above, uncomment this) ---------
  # services.llama-cpp = {
  #   enable = true;
  #   package = pkgs.llama-cpp-vulkan;
  #   host = "0.0.0.0";
  #   port = 8080;
  #   openFirewall = true;
  #   # model = "/var/lib/llama/models/model.gguf";   # option surface varies by
  #   # extraFlags = [ "-ngl" "99" "-c" "8192" "-fa" "on" ]; # nixpkgs version —
  #   #   check: nixos-option services.llama-cpp   before relying on names.
  # };
}
