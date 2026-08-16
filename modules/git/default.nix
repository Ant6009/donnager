{ pkgs, ... }:

{
  users.users.antoine.packages = [ pkgs.git pkgs.gnupg ];

  # System-wide git identity (/etc/gitconfig) — single-user box.
  # Git precedence is local > ~/.gitconfig > /etc/gitconfig; the manual
  # `git config --global` already on the box has identical values, so the
  # two never conflict. This makes the identity declarative and
  # reinstall-proof.
  environment.etc."gitconfig".text = ''
    [user]
      Name = ant6009
      Email = ant.rivoire@gmail.com
    [init]
      defaultBranch = main
    [pull]
      rebase = true
    [commit]
      gpgSign = true
    [gpg]
      format = openpgp
    [gpgsign]
      key = E4B6639BFD0391F3
  '';
}
