#!/bin/bash
# Ollama health check script for LifeOS
# Usage: ollama-health-check.sh [OPTIONS]

set -euo pipefail

OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
TIMEOUT="${TIMEOUT:-5}"
VERBOSE="${VERBOSE:-0}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "$1"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_help() {
    cat << EOF
Ollama Health Check Script

Usage: $0 [OPTIONS]

Options:
    -v, --verbose   Show detailed information
    -t, --timeout   Connection timeout in seconds (default: 5)
    -u, --url       Ollama URL (default: http://localhost:11434)
    -h, --help      Show this help message

Examples:
    $0                  # Quick health check
    $0 -v               # Detailed health check
    $0 -u http://ollama:11434  # Check remote instance
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -t|--timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        -u|--url)
            OLLAMA_URL="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Main health check
check_service() {
    local status=0
    
    # Check if service is responding
    if ! curl -fsSL --max-time "$TIMEOUT" "${OLLAMA_URL}/api/tags" > /dev/null 2>&1; then
        log_error "Ollama service not responding at $OLLAMA_URL"
        return 1
    fi
    
    # Get version
    local version_info
    version_info=$(curl -fsSL --max-time "$TIMEOUT" "${OLLAMA_URL}/api/version" 2>/dev/null || echo '{"version":"unknown"}')
    local version=$(echo "$version_info" | jq -r '.version' 2>/dev/null || echo "unknown")
    
    if [[ $VERBOSE -eq 1 ]]; then
        log_ok "Ollama v${version} is running"
        
        # Count models
        local models
        models=$(curl -fsSL --max-time "$TIMEOUT" "${OLLAMA_URL}/api/tags" 2>/dev/null | jq '.models | length' 2>/dev/null || echo "0")
        log "Installed models: $models"
        
        # GPU info
        if command -v nvidia-smi > /dev/null 2>&1; then
            local gpu_info
            gpu_info=$(nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu --format=csv,noheader 2>/dev/null || echo "Unknown")
            log "GPU: $gpu_info"
        fi
        
        # Memory info
        local mem_info
        mem_info=$(ps -o pid,rss,comm -C ollama 2>/dev/null | tail -1 || echo "N/A")
        if [[ "$mem_info" != "N/A" ]]; then
            log "Memory: $mem_info"
        fi
    else
        echo "OK: Ollama v${version}"
    fi
    
    return 0
}

# Run check
check_service
