{ config, pkgs, lib, ... }:
{
services.searx = {
  enable = true;
  configureUwsgi = true;
  uwsgiConfig = {
    http = "0.0.0.0:8888";
    disable-logging = true;
  };
  settings = {
    server.secret_key = "@SEARXNG_SECRET@";  # move to environmentFile ideally
    server.limiter = false;          # private single-user; avoids needing redis + rate-blocks
    search.formats = [ "html" "json" ];   # <-- THE critical line (see gotcha 1)
  };
};
}
