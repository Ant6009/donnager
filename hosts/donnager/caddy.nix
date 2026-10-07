{ config, pkgs, lib, ... }:

# Reverse proxy in front of Open WebUI so phones get a secure context
# (getUserMedia/mic requires HTTPS or localhost). See docs/openwebui-phone-audio.md.
#
# - `tls internal` = Caddy's private CA; phones trust it once (CA cert lives in
#   /var/lib/caddy after first start).
# - Site address is donnager.lan, resolved by an AdGuard (192.168.68.3)
#   custom DNS query -> 192.168.68.128 (the box's static IP below).
# - Desktops may keep using http://192.168.68.128:3000 until switched over.
{
  services.caddy = {
    enable = true;
    openFirewall = true; # opens 80/443/8080/8443
    virtualHosts."donnager.lan" = {
      # The `locations`/`proxyPass` options don't exist in nixos-26.05's caddy
      # module; site-level reverse_proxy covers all paths.
      extraConfig = ''
        tls internal
        reverse_proxy 127.0.0.1:3000
      '';
    };
  };
}
