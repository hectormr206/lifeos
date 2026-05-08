/* nix/modules/lifeosd.nix
 *
 * NixOS module for lifeosd — the main LifeOS system daemon.
 *
 * Honors Phase 8b UDS+SO_PEERCRED contract:
 * - Fixed UID 970 for SO_PEERCRED predictability (D-4)
 * - DynamicUser = false (required for SO_PEERCRED — D-4 in decisions log)
 * - RuntimeDirectory = "lifeos" provisions /run/lifeos before launch
 * - LIFEOS_API_SOCKET set to the UDS path
 * - LIFEOS_BOOTSTRAP_TOKEN loaded from bootstrapTokenFile (not hardcoded)
 *
 * Satisfies: REQ-3.1, REQ-3.2, REQ-3.3, REQ-3.4, REQ-3.5, REQ-3.6, REQ-12.1
 */
{ config, lib, pkgs, ... }:
let
  cfg = config.services.lifeos.lifeosd;
  inherit (lib) mkEnableOption mkOption mkIf types;
in
{
  options.services.lifeos.lifeosd = {
    enable = mkEnableOption "LifeOS daemon (lifeosd)";

    package = mkOption {
      type = types.package;
      description = ''
        The lifeosd package to use. Normally set to the crane-built
        package from flake outputs: pkgs.lifeosd.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "lifeos";
      description = ''
        System user for lifeosd. MUST be a fixed-UID user (NOT DynamicUser)
        because Phase 8b SO_PEERCRED auth checks the connecting client's UID
        against a known value (970).
      '';
    };

    group = mkOption {
      type = types.str;
      default = "lifeos";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/lifeos";
      description = "Persistent state directory. Owned by the lifeos user.";
    };

    socketPath = mkOption {
      type = types.path;
      default = "/run/lifeos/lifeosd.sock";
      description = ''
        Unix domain socket path for SO_PEERCRED auth (Phase 8b).
        Declared via RuntimeDirectory = "lifeos" so the directory exists
        with correct permissions before the daemon starts.
      '';
    };

    tcpPort = mkOption {
      type = types.port;
      default = 8081;
      description = ''
        Loopback TCP port for legacy clients (browser, dashboard) during
        the UDS migration. Dual-listener mode preserved from Phase 8b.
      '';
    };

    bootstrapTokenFile = mkOption {
      type = types.path;
      description = ''
        Path to a file containing LIFEOS_BOOTSTRAP_TOKEN.
        Provisioned out-of-band (e.g., sops-nix, systemd-creds, or a
        pre-created secrets file). MUST be readable only by the lifeos user.
        Do NOT hardcode this value in any .nix file.
      '';
    };

    sqliteVecPackage = mkOption {
      type = types.package;
      description = ''
        The sqlite-vec C extension package. lifeosd loads it at runtime via
        LIFEOS_SQLITE_VEC_PATH. Separate from rusqlite bundled feature (REQ-2.2).
      '';
    };

    logLevel = mkOption {
      type = types.str;
      default = "info";
      description = "RUST_LOG level for lifeosd.";
    };
  };

  config = mkIf cfg.enable {
    # Provision the systemd service
    systemd.services.lifeosd = {
      description = "LifeOS daemon (lifeosd)";
      documentation = [ "https://github.com/hectormr206/lifeos" ];
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "local-fs.target" ];

      environment = {
        LIFEOS_DATA_DIR = cfg.dataDir;
        LIFEOS_API_SOCKET = cfg.socketPath;
        LIFEOS_API_TCP = "127.0.0.1:${toString cfg.tcpPort}";
        # Runtime-loadable sqlite-vec extension (REQ-2.3)
        LIFEOS_SQLITE_VEC_PATH = "${cfg.sqliteVecPackage}/lib/vec0.so";
        RUST_LOG = cfg.logLevel;
      };

      serviceConfig = {
        # Use "simple" unless lifeosd implements sd_notify (Type = "notify")
        Type = "simple";
        ExecStart = "${cfg.package}/bin/lifeosd";

        # Bootstrap token loaded from file — NOT from nix store (secrets hygiene)
        EnvironmentFile = cfg.bootstrapTokenFile;

        User = cfg.user;
        Group = cfg.group;

        # Runtime + state directories managed by systemd.
        # RuntimeDirectory creates /run/lifeos with mode 0750 before ExecStart.
        # StateDirectory creates /var/lib/lifeos (idempotent, owned by User).
        RuntimeDirectory = "lifeos";
        RuntimeDirectoryMode = "0750";
        StateDirectory = "lifeos";
        StateDirectoryMode = "0750";

        # Precise write access — no broader /var/lib write access
        ReadWritePaths = [ cfg.dataDir "/run/lifeos" ];

        # ===== Hardening block (uniform across all LifeOS services) =====
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        # lifeosd needs no /dev nodes (no GPU, no raw devices)
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK" ];
        LockPersonality = true;
        # MemoryDenyWriteExecute: SQLite may use JIT-like mmap tricks in
        # some configurations; keep false to be safe. If confirmed safe,
        # flip to true in a follow-up. (T-A1-10 REFACTOR note)
        MemoryDenyWriteExecute = false;
        SystemCallArchitectures = "native";
        # Restrict to syscalls needed by a typical Rust async daemon:
        # @system-service covers futex, epoll, read, write, open, socket, etc.
        SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
        # =================================================================

        # Resilience
        Restart = "on-failure";
        RestartSec = "5s";

        # Resource caps — matches current Quadlet config
        MemoryMax = "1G";
      };

      # Post-start health gate: wait up to 60s for the TCP API to accept requests.
      # - Uses TCP (not UDS) to avoid SO_PEERCRED UID gate issues (UID 970 is not
      #   in the allowlist by default — postStart runs as the service user).
      # - Passes the bootstrap token via x-bootstrap-token header because
      #   /api/v1/* routes require it (require_bootstrap_token middleware).
      # - LIFEOS_BOOTSTRAP_TOKEN is available because EnvironmentFile is loaded
      #   before postStart executes.
      postStart = ''
        for i in $(seq 1 60); do
          if ${pkgs.curl}/bin/curl -sf \
              -H "x-bootstrap-token: $LIFEOS_BOOTSTRAP_TOKEN" \
              http://127.0.0.1:${toString cfg.tcpPort}/api/v1/health \
              --max-time 2 \
              > /dev/null 2>&1; then
            exit 0
          fi
          sleep 1
        done
        echo "lifeosd: health check failed after 60s"
        exit 1
      '';
    };
  };
}
