#!/bin/bash
# lifeos-matrix-setup.sh — Idempotent Conduit homeserver setup for LifeOS.
# Runs as ExecStartPre in conduit.service.
# Creates data dirs, config, and the Axi bot user account.

set -euo pipefail

DATA_DIR="/var/lib/lifeos/conduit"
CONFIG_FILE="/etc/lifeos/conduit.toml"
CREDENTIALS_FILE="/etc/lifeos/matrix-axi-credentials"
CONDUIT_PORT=6167
SETUP_MARKER="/var/lib/lifeos/conduit/.setup-done"

# --- 0. Idempotency guard ---
if [ -f "$SETUP_MARKER" ]; then
    echo "[lifeos-matrix-setup] Already configured, skipping"
    exit 0
fi

# --- 1. Data directory ---
mkdir -p "$DATA_DIR"

# --- 2. Config directory ---
mkdir -p /etc/lifeos

# --- 3. Generate config if missing ---
if [ ! -f "$CONFIG_FILE" ]; then
    # Determine server name: use hostname or fallback
    SERVER_NAME=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "lifeos.local")

    cat > "$CONFIG_FILE" <<EOF
[global]
server_name = "${SERVER_NAME}"
database_path = "${DATA_DIR}"
database_backend = "rocksdb"
port = ${CONDUIT_PORT}
address = "0.0.0.0"

# Local-only: no federation
allow_federation = false

# Allow registration for initial user setup (auto-disabled after axi user creation)
allow_registration = true

max_request_size = 20000000

# Disable presence to save resources
allow_check_for_updates = false
EOF

    echo "[lifeos-matrix-setup] Generated $CONFIG_FILE (server=$SERVER_NAME)"
fi

# Read server_name from existing config for user creation
SERVER_NAME=$(grep -oP 'server_name\s*=\s*"\K[^"]+' "$CONFIG_FILE" || echo "lifeos.local")

# --- 4. Create Axi bot user if credentials don't exist ---
if [ ! -f "$CREDENTIALS_FILE" ]; then
    # Generate a strong random password (32 chars, alphanumeric)
    AXI_PASSWORD=$(head -c 48 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)

    # We need Conduit running to register the user.  Since this runs as
    # ExecStartPre, Conduit isn't up yet.  We write a marker file and
    # a oneshot helper will register after Conduit starts.
    #
    # Write credentials now so lifeosd can read them.  The actual Matrix
    # registration happens on first login attempt — Conduit with
    # allow_registration=true will accept the login after we register via API.

    # Save credentials (server_name + password)
    printf '%s\n%s\n' "$SERVER_NAME" "$AXI_PASSWORD" > "$CREDENTIALS_FILE"
    chmod 0600 "$CREDENTIALS_FILE"
    echo "[lifeos-matrix-setup] Generated Axi credentials at $CREDENTIALS_FILE"

    # Write a registration marker — a background task will register the user
    # once Conduit is accepting connections.
    cat > /var/lib/lifeos/conduit/register-axi.sh <<REGEOF
#!/bin/bash
# Auto-register the axi user on Conduit (runs once after first boot).
set -euo pipefail
MAX_WAIT=60
for i in \$(seq 1 \$MAX_WAIT); do
    if curl -sf "http://127.0.0.1:${CONDUIT_PORT}/_matrix/client/versions" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# Register the axi user
PAYLOAD=\$(printf '{"username":"axi","password":"%s","auth":{"type":"m.login.dummy"},"inhibit_login":false}' "${AXI_PASSWORD}")
RESP=\$(curl -sf -X POST "http://127.0.0.1:${CONDUIT_PORT}/_matrix/client/v3/register" \\
    -H "Content-Type: application/json" \\
    -d "\$PAYLOAD" 2>&1) || true

if echo "\$RESP" | grep -q "access_token"; then
    echo "[lifeos-matrix-setup] Axi user registered successfully"
    # Disable open registration now that the bot user exists
    sed -i 's/allow_registration = true/allow_registration = false/' "$CONFIG_FILE"
    rm -f /var/lib/lifeos/conduit/register-axi.sh
elif echo "\$RESP" | grep -q "M_USER_IN_USE"; then
    echo "[lifeos-matrix-setup] Axi user already exists"
    rm -f /var/lib/lifeos/conduit/register-axi.sh
else
    echo "[lifeos-matrix-setup] Registration response: \$RESP"
fi
REGEOF
    chmod +x /var/lib/lifeos/conduit/register-axi.sh

    echo "[lifeos-matrix-setup] Registration script written; will run after Conduit starts"
fi

touch "$SETUP_MARKER"
echo "[lifeos-matrix-setup] Setup complete"
