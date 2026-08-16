{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [
    ../../hardware-configuration.nix
    ./gpu.nix
#    ./llama.nix
    ./openwebui.nix
    ./searx.nix
    ./llama-swap.nix
    ./t2fanrd.nix
    ../../modules/mcp-servers/default.nix
  ];
  
  nixpkgs.config.allowUnfree = true;  

  # ---- Boot ----------------------------------------------------------------
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # Target A (external): Mac firmware finds \EFI\BOOT\BOOTX64.EFI reliably.
  # Uncomment for external installs:
  # boot.loader.efi.canTouchEfiVariables = false;
  # boot.loader.systemd-boot.efiInstallAsRemovable = true;

  # T2 desktops don't need suspend; it's also unreliable. Kill it.
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

  # ---- Networking (wired 10GbE) -------------------------------------------
  networking.hostName = "donnager";
  networking.useDHCP = lib.mkDefault true; # or set a static IP below
  # networking.interfaces.enp5s0.ipv4.addresses = [{
  #   address = "192.168.68.230"; prefixLength = 24;
  # }];
  # networking.defaultGateway = "192.168.68.1";
  # networking.nameservers = [ "192.168.68.3" ];    # your AdGuard LXC

  networking.firewall.allowedTCPPorts = [22 8001 8080 8888 9292];

  # ---- Headless / SSH ------------------------------------------------------
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    settings.PermitRootLogin = "no";
  };

  users.users.antoine = {
    isNormalUser = true;
    extraGroups = ["wheel" "video" "render"];
    openssh.authorizedKeys.keys = [ 
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJixPpkSmWnkNAwXZ2t8xZLUqNJbLPmvNvGrlsJa1wpf ant.rivoire@gmail.com"

    ];
  };
  security.sudo.wheelNeedsPassword = false; # convenience on a lab box; your call
  # ---- MCP Servers ---------------------------------------------------------

  services.mcp-servers = {
    enable = true;
    servers = {
      nixos = {
        package = pkgs.mcp-nixos;
        transport = "http";
        httpPort = 8001;
        httpHost = "0.0.0.0";
        httpPath = "/mcp";
      };
    };
  };

  # ---- Niceties ------------------------------------------------------------
  nix.settings.experimental-features = ["nix-command" "flakes"];
  nix.settings.substituters = ["https://cache.soopy.moe"];
  nix.settings.trusted-public-keys = [
    "cache.soopy.moe-1:0RZVsQeR+GOh0VQI9rvnHz55nVXkFardDqfm4+afjPo="
  ];

  environment.systemPackages = with pkgs; [
    vim
    git
    htop
    btop
    tmux
    vulkan-tools # vulkaninfo
    radeontop # GPU load/VRAM monitor
    pciutils
    lm_sensors
    python313Packages.huggingface-hub
    mcp-nixos
    nvtopPackages.amd
  ];

nixpkgs.overlays = [
  (final: prev: {
    python314Frictionless = prev.python314Frictionless.overrideAttrs (old: {
      doCheck = false;
    });
  })
];
  time.timeZone = "Europe/London";
  system.stateVersion = "25.11"; # match your nixpkgs
}
