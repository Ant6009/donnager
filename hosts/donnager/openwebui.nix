{config, pkgs, lib, ... }:
{
services.open-webui = {
  enable = true;
  host = "0.0.0.0";
  port = 3000;
  # Port 3000 is opened in default.nix (no openFirewall here); Caddy
  # (caddy.nix) fronts it on https://donnager.lan for phones.
  environment = {
    OPENAI_API_BASE_URL = "http://127.0.0.1:9292/v1";   # llama-server directly
    OPENAI_API_KEY = "sk-noauth";                        # ignored unless you set --api-key
    ENABLE_OLLAMA_API = "False";
    # Local STT: nixpkgs' open-webui bundles faster-whisper, so no extra
    # services. Model downloads to /var/lib/open-webui/data/cache/whisper/
    # models on first use (needs outbound internet once).
    WHISPER_MODEL = "base";
    WHISPER_COMPUTE_TYPE = "int8";  # CPU is fine on this box
    WEBUI_AUTH = "True";
    ANONYMIZED_TELEMETRY = "False";
    ENABLE_WEB_SEARCH = "True";
    WEB_SEARCH_ENGINE = "searxng";
    SEARXNG_QUERY_URL = "http://127.0.0.1:8888/search?q=<query>";
    WEB_SEARCH_RESULT_COUNT = "4";
    WEB_SEARCH_CONCURRENT_REQUESTS = "10";
  };
};
}
