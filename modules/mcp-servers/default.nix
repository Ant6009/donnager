# modules/mcp-servers/default.nix
{ config, lib, pkgs, ... }:
let
  cfg = config.services.mcp-servers;
in
{
  options.services.mcp-servers = {
    enable = lib.mkEnableOption "MCP servers running as systemd system services";
    user = lib.mkOption {
      type = lib.types.str;
      default = "mcp";
      description = "System user to run MCP servers as";
    };
    servers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "this MCP server" // { default = true; };
          package = lib.mkOption {
            type = lib.types.package;
            description = "The MCP server package";
          };
          transport = lib.mkOption {
            type = lib.types.enum [ "stdio" "http" ];
            default = "stdio";
            description = "MCP transport mode";
          };
          httpHost = lib.mkOption {
            type = lib.types.str;
            default = "0.0.0.0";
            description = "HTTP bind address (transport=http only)";
          };
          httpPort = lib.mkOption {
            type = lib.types.port;
            default = 8000;
            description = "HTTP port (transport=http only)";
          };
          httpPath = lib.mkOption {
            type = lib.types.str;
            default = "/mcp";
            description = "HTTP endpoint path (transport=http only)";
          };
          openFirewall = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether to open the firewall for httpPort";
          };
          extraArgs = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Extra CLI arguments";
          };
          extraEnv = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Extra environment variables";
          };
        };
      });
      default = { };
      description = "Map of MCP server names to their configuration";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.user;
      description = "MCP servers service account";
    };
    users.groups.${cfg.user} = { };

    systemd.services = lib.mapAttrs' (name: srv:
      lib.nameValuePair "mcp-${name}" {
        enable = srv.enable;
        description = "MCP server: ${name}";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${lib.getExe srv.package} ${lib.concatStringsSep " " srv.extraArgs}";
          Restart = "on-failure";
          User = cfg.user;
          Group = cfg.user;
          DynamicUser = lib.mkForce false;
          # Basic hardening
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          Environment =
            (lib.mapAttrsToList (k: v: "${k}=${v}") srv.extraEnv) ++
            lib.optionals (srv.transport == "http") [
              "MCP_NIXOS_TRANSPORT=http"
              "MCP_NIXOS_HOST=${srv.httpHost}"
              "MCP_NIXOS_PORT=${builtins.toString srv.httpPort}"
              "MCP_NIXOS_PATH=${srv.httpPath}"
            ];
        };
      }
    ) cfg.servers;

    networking.firewall.allowedTCPPorts =
      lib.flatten (lib.mapAttrsToList
        (name: srv: lib.optional (srv.transport == "http" && srv.openFirewall) srv.httpPort)
        cfg.servers);
  };
}
