#!/bin/bash
# LifeOS First Boot Script
# Handles initial system setup including Ollama installation

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
    clear
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
    echo -e "  ${BOLD}life ask \"hello\"${NC} - Ask the AI anything"
    echo ""
    
    echo -e "${CYAN}Default Models:${NC}"
    echo -e "  • ${BOLD}qwen3:8b${NC}    - Fast, efficient general assistant"
    echo -e "  • ${BOLD}llama3.2:3b${NC} - Lightweight, quick responses"
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
    mkdir -p /var/log
    mkdir -p /etc/lifeos
    
    # Set up user directories if needed
    if [ -d /home/user ]; then
        xdg-user-dirs-update --force 2>/dev/null || true
    fi
    
    log_success "System directories created"
}

# Install and configure Ollama
setup_ollama() {
    log "Setting up Ollama AI runtime..."
    
    if [ -f /usr/local/bin/ollama-install.sh ]; then
        chmod +x /usr/local/bin/ollama-install.sh
        if /usr/local/bin/ollama-install.sh install 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Ollama installed successfully"
        else
            log_warn "Ollama installation had issues - will retry on next boot"
        fi
    else
        log_warn "Ollama installer not found - skipping AI setup"
    fi
}

# Configure GPU if present
configure_gpu() {
    log "Detecting and configuring GPU..."
    
    # Check for NVIDIA
    if command -v nvidia-smi &> /dev/null; then
        local nvidia_info=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null || echo "Unknown")
        log_success "NVIDIA GPU detected: $nvidia_info"
        
        # Ensure nvidia-persistenced is running for better performance
        if systemctl enable nvidia-persistenced 2>/dev/null; then
            systemctl start nvidia-persistenced 2>/dev/null || true
        fi
    fi
    
    # Check for AMD
    if command -v rocminfo &> /dev/null || lspci 2>/dev/null | grep -qi amd; then
        log_success "AMD GPU detected"
    fi
    
    # Check for Intel
    if lspci 2>/dev/null | grep -qi "intel.*vga"; then
        log_success "Intel GPU detected"
    fi
}

# Start essential services
start_services() {
    log "Starting essential services..."
    
    # Start Ollama if installed
    if systemctl is-enabled ollama.service &>/dev/null; then
        log "Starting Ollama service..."
        systemctl start ollama.service && log_success "Ollama started" || log_warn "Failed to start Ollama"
    fi
    
    # Other services can be added here
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
    
    # Check Ollama
    if command -v ollama &> /dev/null; then
        local ollama_version=$(ollama --version 2>/dev/null | head -1 || echo "unknown")
        log_success "Ollama installed: $ollama_version"
    else
        log_warn "Ollama not installed (may install on demand)"
    fi
    
    # Check services
    if systemctl is-active ollama.service &>/dev/null; then
        log_success "Ollama service is running"
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
    setup_ollama
    start_services
    setup_completion
    verify_installation
    mark_complete
    
    print_complete
    
    log "First boot setup complete!"
}

# Run main
main "$@"
