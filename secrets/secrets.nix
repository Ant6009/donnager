# Recipient rules for the agenix CLI.
# NOT imported into the NixOS configuration — only read by `agenix -e/-r`
# via the RULES env var (default ./secrets.nix, run from the repo root:
#   RULES=./secrets/secrets.nix nix run github:ryantm/agenix -- -e secrets/<name>.age)
#
# Keys are PUBLIC (age or ssh format) — safe to commit. The matching
# private keys never leave their machine:
#   - donnager: SSH host key /etc/ssh/ssh_host_ed25519_key (module default)
#
# To share a secret with another machine, add its public key to the list.
# To add a machine to ALL secrets: update the lists, then
#   RULES=./secrets/secrets.nix nix run github:ryantm/agenix -- -r
let
  donnager = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID2DOgBkhTJ1aB55xmZjd/+lgKQuAkgkBBpOPQFVt9GC root@macpro";
in
{
  # systemd-EnvironmentFile content: SEARX_SECRET_KEY=<hex>
  # Consumed via services.searx.environmentFile + $SEARX_SECRET_KEY (envsubst).
  # NOTE: key must match the FILE argument exactly (invoke from repo root).
  "secrets/searxng.age".publicKeys = [ donnager ];
}
