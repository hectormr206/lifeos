#!/bin/bash
# LifeOS First Boot Script
# Handles initial system setup including AI runtime (llama-server)

set -euo pipefail

LIFEOS_CONFIG_DIR="/etc/lifeos"
FIRST_BOOT_MARKER="/var/lib/lifeos/.first-boot-complete"
LOG_FILE="/var/log/lifeos-first-boot.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Logging
log() {
    echo -e "${BLUE}[LifeOS]${NC} $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[!]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1" | tee -a "$LOG_FILE"
}

# Print welcome banner
print_welcome() {
    # In systemd first-boot service there is no interactive TTY.
    if [[ -t 1 ]] && command -v clear &>/dev/null; then
        clear || true
    fi
    echo -e "${CYAN}"
    cat << "EOF"
    __    _ __    ______            __
   / /   (_) /_  / ____/___  ____  / /__
  / /   / / __ \/ /   / __ \/ __ \/ //_/
 / /___/ / /_/ / /___/ /_/ / /_/ / ,<
/_____/_/_.___/\____/\____/\____/_/|_|

EOF
    echo -e "${NC}"
    echo -e "${BOLD}Welcome to LifeOS!${NC}"
    echo -e "Setting up your AI-powered personal operating system...\n"
    echo -e "${YELLOW}This will take a few minutes.${NC}\n"
}

# Print completion banner
print_complete() {
    echo -e "\n${GREEN}${BOLD}"
    cat << "EOF"
┌─────────────────────────────────────────┐
│                                         │
│   🎉 LifeOS Setup Complete! 🎉         │
│                                         │
└─────────────────────────────────────────┘
EOF
    echo -e "${NC}"
    echo -e "${BOLD}Your AI assistant is ready!${NC}\n"

    echo -e "${CYAN}Quick Start Commands:${NC}"
    echo -e "  ${BOLD}life ai start${NC}      - Start AI services"
    echo -e "  ${BOLD}life ai chat${NC}       - Chat with your AI"
    echo -e "  ${BOLD}life ai models${NC}     - List available models"
    echo -e "  ${BOLD}life ai status${NC}     - Check AI service status"
    echo -e "  ${BOLD}life ai ask \"hello\"${NC} - Ask the AI anything"
    echo ""

    echo -e "${CYAN}AI Runtime: llama-server (llama.cpp)${NC}"
    echo -e "  Models are stored in /var/lib/lifeos/models/"
    echo -e "  API available at http://localhost:8082/v1/"
    echo ""

    echo -e "${YELLOW}Tip:${NC} Run ${BOLD}life${NC} to see all available commands.\n"
}

# Check if first boot already completed
check_first_boot() {
    if [ -f "$FIRST_BOOT_MARKER" ]; then
        log "First boot already completed."
        exit 0
    fi
}

# System setup
system_setup() {
    log "Performing system setup..."

    # Create necessary directories
    mkdir -p /var/lib/lifeos
    if [[ ! -e /var/lib/lifeos/models ]]; then
        mkdir -p /var/lib/lifeos/models
    fi
    mkdir -p /var/log
    mkdir -p /etc/lifeos

    # Set up user directories if needed
    if [ -d /home/user ]; then
        xdg-user-dirs-update --force 2>/dev/null || true
    fi

    # Install GRUB theme (safe — only touches /boot/grub2/themes/)
    if [ -x /usr/local/bin/lifeos-grub-theme.sh ]; then
        /usr/local/bin/lifeos-grub-theme.sh || log_warn "GRUB theme installation failed (non-fatal)"
    fi

    # Set up Flatpak
    flatpak remote-add --if-not-exists --system flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
    flatpak remote-modify --system --enable flathub 2>/dev/null || true
    flatpak remote-add --if-not-exists --system cosmic https://flatpak.pop-os.org/repo/ 2>/dev/null || true

    # Create LLM providers env template if it doesn't exist
    if [ ! -f /etc/lifeos/llm-providers.env ]; then
        cat > /etc/lifeos/llm-providers.env << 'ENVEOF'
# LifeOS LLM Provider API Keys
# Configure your keys here. The daemon loads them at startup.
# Only fill the ones you use — the router handles fallbacks.
#
# HIGH PRIVACY (recommended): Cerebras, Groq
# See /usr/share/doc/lifeos/llm-providers.env.example for all options.

# Cerebras (FREE, zero data retention, 2000+ tok/s)
CEREBRAS_API_KEY=
# Groq (FREE, zero data retention, 500-1000 tok/s)
GROQ_API_KEY=
# OpenRouter (FREE models, mixed privacy)
OPENROUTER_API_KEY=
# Telegram Bot (optional, for remote control)
LIFEOS_TELEGRAM_BOT_TOKEN=
LIFEOS_TELEGRAM_CHAT_ID=
ENVEOF
        chmod 600 /etc/lifeos/llm-providers.env
        log_success "LLM providers config created at /etc/lifeos/llm-providers.env"
    fi

    # Initialize battery charge threshold (default 80% for battery health)
    if [ ! -f /etc/lifeos/battery-threshold ]; then
        echo "80" > /etc/lifeos/battery-threshold
        log_success "Battery charge threshold initialized (80%)"
    fi

    # Ensure wake word model is available in writable location
    if [ ! -f /var/lib/lifeos/models/rustpotter/axi.rpw ] && \
       [ -f /usr/share/lifeos/models/rustpotter/axi.rpw ]; then
        mkdir -p /var/lib/lifeos/models/rustpotter
        cp /usr/share/lifeos/models/rustpotter/axi.rpw /var/lib/lifeos/models/rustpotter/axi.rpw
        log_success "Wake word model copied to writable location"
    fi

    log_success "System directories created"
}

# Configure GPU if present and update llama-server env
configure_gpu() {
    log "Detecting and configuring GPU..."

    local gpu_layers=0
    local env_file="/etc/lifeos/llama-server.env"
    local has_nvidia_gpu=0
    local nvidia_runtime_ready=0
    local usr_read_only=0

    if lspci 2>/dev/null | grep -Eqi 'vga|3d|display' && lspci 2>/dev/null | grep -Eqi 'nvidia'; then
        has_nvidia_gpu=1
    fi

    if findmnt -n -o OPTIONS /usr 2>/dev/null | grep -qw ro; then
        usr_read_only=1
    fi

    # Check for NVIDIA runtime readiness
    if [[ "$has_nvidia_gpu" -eq 1 ]]; then
        if command -v nvidia-smi &>/dev/null && nvidia-smi -L >/dev/null 2>&1; then
            nvidia_runtime_ready=1
        fi

        # Attempt to build/load NVIDIA module if GPU exists but runtime is not ready yet
        if [[ "$nvidia_runtime_ready" -eq 0 ]]; then
            log_warn "NVIDIA GPU detected but nvidia-smi is not operational yet"
            if command -v mokutil &>/dev/null && mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"; then
                if command -v /usr/local/bin/lifeos-nvidia-secureboot.sh &>/dev/null; then
                    if ! /usr/local/bin/lifeos-nvidia-secureboot.sh status >/dev/null 2>&1; then
                        if [[ -f /usr/share/lifeos/secureboot/lifeos-nvidia-kmod.der ]]; then
                            log_warn "Secure Boot + NVIDIA requires key enrollment. Run: sudo lifeos-nvidia-secureboot.sh enroll && sudo reboot"
                        else
                            log_warn "Secure Boot + NVIDIA: image is missing LifeOS MOK cert (/usr/share/lifeos/secureboot/lifeos-nvidia-kmod.der)"
                            log_warn "Update/pull a signed LifeOS image build (NVIDIA Secure Boot signing enabled)."
                        fi
                    fi
                fi
            fi
            if [[ "$usr_read_only" -eq 1 ]]; then
                log_warn "Skipping akmods on read-only image-mode host; NVIDIA kmod must come from image update/layered deployment"
            elif command -v akmods &>/dev/null; then
                log "Trying to build NVIDIA kmod for kernel $(uname -r) with akmods..."
                if akmods --force --kernels "$(uname -r)" >>"$LOG_FILE" 2>&1; then
                    log_success "akmods build completed for kernel $(uname -r)"
                else
                    log_warn "akmods build failed (Secure Boot or driver support may be blocking)"
                fi
            fi

            if command -v modprobe &>/dev/null; then
                modprobe nvidia >/dev/null 2>&1 || true
            fi

            if command -v nvidia-smi &>/dev/null && nvidia-smi -L >/dev/null 2>&1; then
                nvidia_runtime_ready=1
            fi
        fi

        if [[ "$nvidia_runtime_ready" -eq 1 ]]; then
            local nvidia_info
            nvidia_info=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null || echo "Unknown")
            log_success "NVIDIA GPU detected: $nvidia_info"
            gpu_layers=-1  # Offload all layers to GPU

            # Ensure nvidia-persistenced is running only when NVIDIA runtime is really active
            if systemctl enable nvidia-persistenced 2>/dev/null; then
                if systemctl start nvidia-persistenced 2>/dev/null; then
                    log_success "nvidia-persistenced enabled"
                else
                    log_warn "Could not start nvidia-persistenced"
                fi
            fi
        else
            if lsmod 2>/dev/null | grep -q '^nouveau'; then
                log_warn "NVIDIA proprietary driver not active; nouveau is loaded (graphics fallback)"
            else
                log_warn "NVIDIA proprietary driver not active; using CPU/iGPU fallback"
            fi

            # Keep systemd clean in cases where the service was previously enabled but runtime is absent.
            systemctl disable nvidia-persistenced >/dev/null 2>&1 || true
            systemctl stop nvidia-persistenced >/dev/null 2>&1 || true
            systemctl reset-failed nvidia-persistenced >/dev/null 2>&1 || true
        fi
    fi

    # Check for AMD
    if [ "$gpu_layers" -eq 0 ] && (command -v rocminfo &> /dev/null || lspci 2>/dev/null | grep -qi amd); then
        log_success "AMD GPU detected"
        gpu_layers=-1
    fi

    # Check for Intel
    if [ "$gpu_layers" -eq 0 ] && lspci 2>/dev/null | grep -qi "intel.*vga"; then
        log_success "Intel GPU detected"
    fi

    # Update llama-server env with GPU config
    if [ -f "$env_file" ] && [ "$gpu_layers" -ne 0 ]; then
        sed -i "s/^LIFEOS_AI_GPU_LAYERS=.*/LIFEOS_AI_GPU_LAYERS=$gpu_layers/" "$env_file"
        log_success "GPU acceleration enabled (gpu_layers=$gpu_layers)"
    fi
}

# Set up AI runtime (llama-server)
setup_ai() {
    log "Setting up AI runtime (llama-server)..."

    if [ -x /usr/local/bin/lifeos-ai-setup.sh ]; then
        if /usr/local/bin/lifeos-ai-setup.sh 2>&1 | tee -a "$LOG_FILE"; then
            log_success "AI model ready"
        else
            log_warn "AI model download had issues - service will retry on start"
        fi
    else
        log_warn "AI setup script not found - skipping model download"
    fi
}

# Start essential services
start_services() {
    log "Starting essential services..."

    # Start llama-server if installed
    if systemctl is-enabled llama-server.service &>/dev/null; then
        log "Starting llama-server service..."
        systemctl start llama-server.service && log_success "llama-server started" || log_warn "Failed to start llama-server"
    fi
}

# Set up CLI auto-completion
setup_completion() {
    log "Setting up shell completions..."

    # Bash completion
    if [ -d /etc/bash_completion.d ]; then
        life completions bash > /etc/bash_completion.d/life 2>/dev/null || true
    fi

    # Fish completion
    if [ -d /usr/share/fish/vendor_completions.d ]; then
        life completions fish > /usr/share/fish/vendor_completions.d/life.fish 2>/dev/null || true
    fi

    log_success "Shell completions installed"
}

# Verify installation
verify_installation() {
    log "Verifying installation..."

    local issues=0

    # Check life CLI
    if ! command -v life &> /dev/null; then
        log_error "life CLI not found in PATH"
        ((issues++))
    else
        log_success "life CLI installed"
    fi

    # Check llama-server
    if command -v llama-server &> /dev/null; then
        log_success "llama-server installed"
    else
        log_warn "llama-server not found"
        ((issues++))
    fi

    # Check if model exists
    if ls /var/lib/lifeos/models/*.gguf &>/dev/null; then
        log_success "AI model(s) available"
    else
        log_warn "No AI models found (will download on service start)"
    fi

    # Check services
    if systemctl is-active llama-server.service &>/dev/null; then
        log_success "llama-server service is running"
    fi

    # Check security baseline (Secure Boot + LUKS2)
    if [ -x /usr/local/bin/lifeos-security-baseline-check.sh ]; then
        if /usr/local/bin/lifeos-security-baseline-check.sh --quiet; then
            log_success "Security baseline validated (Secure Boot + LUKS2)"
        else
            log_error "Security baseline validation failed"
            ((issues++))
        fi
    fi

    return $issues
}

# Mark first boot as complete
mark_complete() {
    local timestamp=$(date -Iseconds)
    echo "First boot completed: $timestamp" > "$FIRST_BOOT_MARKER"
    log_success "First boot setup marked complete"
}

# Handle errors
error_handler() {
    local line=$1
    log_error "Error occurred at line $line"
    log "Check $LOG_FILE for details"
    exit 1
}

trap 'error_handler $LINENO' ERR

# Main execution
main() {
    # Ensure log directory exists
    mkdir -p "$(dirname "$LOG_FILE")"

    # Redirect all output to log file as well
    exec 1> >(tee -a "$LOG_FILE")
    exec 2> >(tee -a "$LOG_FILE" >&2)

    check_first_boot
    print_welcome

    log "Starting LifeOS first-boot setup..."
    log "Log file: $LOG_FILE"

    system_setup
    configure_gpu
    setup_ai
    start_services
    setup_completion
    verify_installation || true
    mark_complete

    print_complete

    log "First boot setup complete!"
}

# Run main
main "$@"
