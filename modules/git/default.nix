{ pkgs, ... }:

{
  users.users.antoine.packages = [ pkgs.git pkgs.gnupg ];

  # System-wide git preferences (/etc/gitconfig) — single-user box.
  # Personal identity (Name/Email) and GPG signing key are intentionally
  # NOT declared here (kept private); set them with `git config --global`.
  # Git precedence is local > ~/.gitconfig > /etc/gitconfig, so the
  # per-user config wins and this only provides shared defaults.
  environment.etc."gitconfig".text = ''
    [init]
      defaultBranch = main
    [pull]
      rebase = true
  '';
}
