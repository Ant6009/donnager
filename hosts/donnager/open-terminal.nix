{ config, pkgs, lib, llmPkgs, ... }:

# Open Terminal: the agent "computer" that Open WebUI acts through (file
# browser, PTY terminals, command execution, notebooks).
# Upstream: https://github.com/open-webui/open-terminal (MIT, Python 3.11+).
#
# Layout: bare metal, single user, bound to 127.0.0.1:8000.
# Open WebUI proxies server-side (Admin Settings -> Integrations -> Open
# Terminal -> http://127.0.0.1:8000), so no firewall port is opened and the LAN
# cannot reach it directly. Docker is the isolated option upstream prefers, but
# the image's value is its toolkit (node, build tools, Chromium + virtual
# desktop for the Browser/Desktop tabs), which the nixpkgs build at 0.14.8 does
# not ship anyway. Isolation here is "unprivileged user + closed firewall", not
# a sandbox.
#
# SECURITY: the bearer key IS a shell as the `open-terminal` user. Bare metal
# means that user can read anything world-readable (the model dir, ...) and can
# disturb the host (kill llama-server, fill /var). It is kept out of
# wheel/video/render, its writable area is /var/lib/open-terminal, and the key
# is an agenix blob readable only by root and that group.
#
# Package source: `llmPkgs` (flake.nix), a pinned second nixpkgs. The locked
# main nixpkgs (2026-10-23) predates the open-terminal package, so it is not
# available without a full userspace bump. Update with `nix flake update
# llmPkgs`, which moves only open-terminal and its python deps.
{
  age.secrets."open-terminal" = {
    file = ../../secrets/open-terminal.age;
    # Contents are the raw bearer key (open-terminal strips trailing newline).
    # OPEN_TERMINAL_API_KEY_FILE keeps it out of the unit's environment.
    mode = "0440";
    group = "open-terminal";
    # agenix default identity: /etc/ssh/ssh_host_ed25519_key on donnager.
  };

  users.groups.open-terminal = { };
  users.users.open-terminal = {
    isSystemUser = true;
    group = "open-terminal";
    home = "/var/lib/open-terminal"; # created+owned via StateDirectory below
    description = "Open Terminal service account";
  };

  systemd.services.open-terminal = {
    description = "Open Terminal API for Open WebUI agents";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      # Single-user mode: everything the API exposes is rooted at $HOME.
      HOME = "/var/lib/open-terminal";
      SHELL = "${pkgs.bash}/bin/bash";
      LANG = "en_US.UTF-8";
      # The agent's shell PATH. Add tools here, not in
      # environment.systemPackages: the service gets its own PATH.
      # mkForce because the systemd module seeds a default PATH for every
      # unit (coreutils/findutils/gnugrep/gnused/systemd).
      PATH = lib.mkForce (lib.makeBinPath (with pkgs; [
        bash
        coreutils
        gnugrep
        gnused
        gawk
        gnutar
        gzip
        bzip2
        xz
        findutils
        diffutils
        which
        procps
        util-linux
        ripgrep
        fd
        jq
        curl
        git
        python3
        nodejs
        nano
      ]));

      OPEN_TERMINAL_API_KEY_FILE = config.age.secrets."open-terminal".path;
      OPEN_TERMINAL_FILE_BROWSER_ROOT = "home"; # file browser stays under HOME
      OPEN_TERMINAL_MAX_SESSIONS = "8";
      OPEN_TERMINAL_EXECUTE_TIMEOUT = "3600"; # per command, seconds
    };

    serviceConfig = {
      # --host is explicit: without it open-terminal binds 0.0.0.0.
      ExecStart = lib.concatStringsSep " " [
        (lib.getExe llmPkgs.open-terminal)
        "run"
        "--host 127.0.0.1"
        "--port 8000"
        "--cwd /var/lib/open-terminal"
        "--cors-allowed-origins https://donnager.lan"
      ];
      User = "open-terminal";
      Group = "open-terminal";
      WorkingDirectory = "/var/lib/open-terminal";
      StateDirectory = "open-terminal";
      StateDirectoryMode = "0700";
      Restart = "always";
      RestartSec = 5;

      # Hardening that does not break "the agent installs packages and runs
      # servers". PrivateDevices is deliberately NOT set, so nvidia-smi works
      # inside a terminal. ProtectSystem=full (not strict) keeps /var writable
      # for StateDirectory and pip/npm caches under HOME.
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "full";
      ProtectHome = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectHostname = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      RestrictRealtime = true;
      LockPersonality = true;
      SystemCallArchitectures = "native";
      # Caps so a runaway build cannot starve llama-server (94 GB RAM box).
      MemoryHigh = "8G";
      MemoryMax = "16G";
      TasksMax = 1024;
      LimitNOFILE = 65536;
    };
  };

  # Open WebUI reads and caches every terminal connection's OpenAPI spec when
  # it starts (backend/open_webui/utils/tools.py, set_terminal_servers), so it
  # must come up after the terminal. Restart open-webui after adding or
  # removing a connection in the UI.
  systemd.services.open-webui = {
    after = [ "open-terminal.service" ];
    wants = [ "open-terminal.service" ];
  };
}
