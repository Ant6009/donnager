{ config, pkgs, lib, ... }:
{
  # age-encrypted secret (blob committed in secrets/, decrypted at
  # activation to /run/agenix/searxng using the machine's SSH host key).
  # Content is a systemd EnvironmentFile: SEARX_SECRET_KEY=<hex>
  age.secrets."searxng" = {
    file = ../../secrets/searxng.age;
  };

  services.searx = {
    enable = true;
    configureUwsgi = true;
    uwsgiConfig = {
      http = "0.0.0.0:8888";
      disable-logging = true;
    };
    # systemd loads the decrypted file into the service environment; the
    # module's ExecStartPre runs envsubst, so $SEARX_SECRET_KEY below is
    # resolved at service start. The key never touches the repo or store.
    environmentFile = config.age.secrets."searxng".path;
    settings = {
      server.secret_key = "$SEARX_SECRET_KEY";
      server.limiter = false;          # private single-user; avoids needing redis + rate-blocks
      search.formats = [ "html" "json" ];   # <-- THE critical line (see gotcha 1)
    };
  };
}
