{ pkgs, ...}:

{
  user.user.antoine.packages =  [pakgs.git pkgs.gnupg];
  user.user.antoine.files."./.gitconfig".text = ''
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
