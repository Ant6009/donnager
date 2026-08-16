{config, pkgs, lib, ... }:
{
services.open-webui = {
  enable = true;
  host = "0.0.0.0";
  port = 3000;
  openFirewall = true;
  environment = {
    OPENAI_API_BASE_URL = "http://127.0.0.1:9292/v1";   # llama-server directly
    OPENAI_API_KEY = "sk-noauth";                        # ignored unless you set --api-key
    dataDir = "/var/lib/open-webui";
    ENABLE_OLLAMA_API = "False";
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
