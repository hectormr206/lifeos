#!/bin/bash
#===============================================================================
# LifeOS Beta Feedback Collector
#===============================================================================
# Collects feedback from beta testers and submits to the appropriate channels.
#
# Usage: life feedback [bug|feature|general]
#===============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/lifeos"
FEEDBACK_DIR="$CONFIG_DIR/feedback"
API_ENDPOINT="${LIFEOS_API:-https://api.lifeos.io/v1/feedback}"
GITHUB_REPO="${LIFEOS_REPO:-hectormr/lifeos}"

# Ensure directories exist
mkdir -p "$FEEDBACK_DIR"

# Show help
show_help() {
    cat << EOF
LifeOS Beta Feedback Collector

Collect and submit feedback for the LifeOS Beta Program.

USAGE:
    life feedback <COMMAND> [OPTIONS]

COMMANDS:
    bug         Report a bug or issue
    feature     Suggest a new feature
    general     General feedback or praise
    status      Check feedback submission status

OPTIONS:
    --attach FILE       Attach a file (logs, screenshots)
    --hardware          Include hardware information
    --anonymous         Submit anonymously
    --github            Also create GitHub issue
    -h, --help          Show this help

EXAMPLES:
    # Report a bug
    life feedback bug

    # Suggest a feature with hardware info
    life feedback feature --hardware

    # Report with attachment
    life feedback bug --attach /var/log/lifeos/error.log

ENVIRONMENT:
    LIFEOS_BETA_ID      Your beta tester ID
    LIFEOS_API          API endpoint URL
    LIFEOS_REPO         GitHub repository
EOF
}

# Get system information
gather_system_info() {
    local info=""
    
    info+="LifeOS Version: $(life --version 2>/dev/null || echo 'unknown')\n"
    info+="Kernel: $(uname -r)\n"
    info+="Architecture: $(uname -m)\n"
    info+="Hostname: $(hostname)\n"
    
    if [[ -f /etc/os-release ]]; then
        info+="OS: $(source /etc/os-release && echo "$PRETTY_NAME")\n"
    fi
    
    if [[ "${1:-}" == "--hardware" ]]; then
        info+="\nHardware Information:\n"
        info+="CPU: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)\n"
        info+"Memory: $(free -h | awk '/^Mem:/ {print $2}')\n"
        
        if command -v lspci &> /dev/null; then
            info+"GPU: $(lspci | grep -i vga | head -1 | cut -d: -f3 | xargs)\n"
        fi
        
        info+"Disk: $(df -h / | awk 'NR==2 {print $2}')\n"
    fi
    
    echo -e "$info"
}

# Collect bug report
collect_bug_report() {
    echo -e "${BLUE}LifeOS Bug Report${NC}"
    echo "=================="
    echo
    
    # Title
    echo -n "Bug title (brief description): "
    read -r title
    
    # Category
    echo
    echo "Category:"
    select category in "System" "AI" "Desktop" "App Store" "Installation" "Performance" "Other"; do
        break
    done
    
    # Severity
    echo
    echo "Severity:"
    select severity in "🔴 Critical" "🟠 High" "🟡 Medium" "🟢 Low"; do
        break
    done
    
    # Steps to reproduce
    echo
    echo "Steps to reproduce (one per line, empty line to finish):"
    local steps=""
    local step_num=1
    while true; do
        echo -n "Step $step_num: "
        read -r step
        if [[ -z "$step" ]]; then
            break
        fi
        steps+="$step\n"
        ((step_num++))
    done
    
    # Expected behavior
    echo
    echo -n "Expected behavior: "
    read -r expected
    
    # Actual behavior
    echo
    echo -n "Actual behavior: "
    read -r actual
    
    # Additional context
    echo
    echo -n "Additional context (optional): "
    read -r context
    
    # Generate report
    local report_file="$FEEDBACK_DIR/bug-$(date +%Y%m%d-%H%M%S).md"
    
    cat > "$report_file" << EOF
## Bug Report

**Title:** $title

**Category:** $category

**Severity:** $severity

**Reported:** $(date -Iseconds)

**Beta ID:** ${LIFEOS_BETA_ID:-"Not provided"}

### Steps to Reproduce
$steps

### Expected Behavior
$expected

### Actual Behavior
$actual

### Additional Context
$context

### System Information
$(gather_system_info --hardware)

### Attachments
EOF
    
    echo
    echo -e "${GREEN}✓ Bug report saved to: $report_file${NC}"
    
    # Show report
    echo
    echo -e "${CYAN}Report Preview:${NC}"
    echo "---"
    cat "$report_file"
    echo "---"
    
    echo
    echo -n "Submit this report? [Y/n] "
    read -r confirm
    
    if [[ -z "$confirm" || "$confirm" =~ ^[Yy]$ ]]; then
        submit_report "$report_file" "bug"
    else
        echo -e "${YELLOW}Report saved but not submitted. You can submit later with:${NC}"
        echo "  life feedback submit $report_file"
    fi
}

# Collect feature request
collect_feature_request() {
    echo -e "${BLUE}LifeOS Feature Request${NC}"
    echo "======================="
    echo
    
    # Title
    echo -n "Feature title: "
    read -r title
    
    # Category
    echo
    echo "Category:"
    select category in "AI" "Desktop" "System" "App Store" "Developer Tools" "Accessibility" "Other"; do
        break
    done
    
    # Problem statement
    echo
    echo "What problem does this solve?"
    read -r problem
    
    # Proposed solution
    echo
    echo "Describe your proposed solution:"
    read -r solution
    
    # Use case
    echo
    echo "Describe a specific use case:"
    echo "As a [type of user], I want [goal], so that [benefit]"
    read -r use_case
    
    # Priority
    echo
    echo "How important is this to you?"
    select priority in "Critical" "High" "Medium" "Low" "Nice to have"; do
        break
    done
    
    # Generate report
    local report_file="$FEEDBACK_DIR/feature-$(date +%Y%m%d-%H%M%S).md"
    
    cat > "$report_file" << EOF
## Feature Request

**Title:** $title

**Category:** $category

**Priority:** $priority

**Submitted:** $(date -Iseconds)

**Beta ID:** ${LIFEOS_BETA_ID:-"Not provided"}

### Problem Statement
$problem

### Proposed Solution
$solution

### Use Case
$use_case

### System Information
$(gather_system_info)
EOF
    
    echo
    echo -e "${GREEN}✓ Feature request saved to: $report_file${NC}"
    
    echo
    echo -n "Submit this request? [Y/n] "
    read -r confirm
    
    if [[ -z "$confirm" || "$confirm" =~ ^[Yy]$ ]]; then
        submit_report "$report_file" "feature"
    fi
}

# Collect general feedback
collect_general_feedback() {
    echo -e "${BLUE}LifeOS General Feedback${NC}"
    echo "========================"
    echo
    
    # Type
    echo "What type of feedback?"
    select feedback_type in "Praise" "Suggestion" "Question" "Other"; do
        break
    done
    
    # Message
    echo
    echo "Your feedback:"
    read -r message
    
    # Rating
    echo
    echo "Overall satisfaction (1-10):"
    select rating in "1 - Very dissatisfied" "2" "3" "4" "5" "6" "7" "8" "9" "10 - Extremely satisfied"; do
        break
    done
    
    # Generate report
    local report_file="$FEEDBACK_DIR/feedback-$(date +%Y%m%d-%H%M%S).md"
    
    cat > "$report_file" << EOF
## General Feedback

**Type:** $feedback_type

**Rating:** $rating

**Submitted:** $(date -Iseconds)

**Beta ID:** ${LIFEOS_BETA_ID:-"Not provided"}

### Feedback
$message

### System Information
$(gather_system_info)
EOF
    
    echo
    echo -e "${GREEN}✓ Feedback saved to: $report_file${NC}"
    
    submit_report "$report_file" "general"
}

# Submit report to appropriate channels
submit_report() {
    local report_file="$1"
    local report_type="$2"
    
    echo -e "${BLUE}Submitting feedback...${NC}"
    
    # Try API submission first
    if command -v curl &> /dev/null; then
        echo "Submitting to LifeOS API..."
        
        local response
        response=$(curl -s -w "%{http_code}" -X POST \
            -H "Content-Type: application/json" \
            -d "{\"type\":\"$report_type\",\"content\":$(jq -Rs . < "$report_file"),\"beta_id\":\"${LIFEOS_BETA_ID:-}\"}" \
            "$API_ENDPOINT" 2>/dev/null || echo "000")
        
        local http_code="${response: -3}"
        
        if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
            echo -e "${GREEN}✓ Successfully submitted to LifeOS API${NC}"
            
            # Mark as submitted
            mv "$report_file" "${report_file}.submitted"
        else
            echo -e "${YELLOW}⚠ API submission failed (HTTP $http_code)${NC}"
            echo "Report saved locally for later submission."
        fi
    fi
    
    # Optionally create GitHub issue
    if [[ "${CREATE_GITHUB_ISSUE:-false}" == true ]]; then
        echo "Opening GitHub issue creation..."
        
        local title
        title=$(grep -m1 "^\*\*Title:\*\*" "$report_file" | sed 's/\*\*Title:\*\* //')
        
        local url="https://github.com/$GITHUB_REPO/issues/new"
        
        if [[ "$report_type" == "bug" ]]; then
            url="$url?template=bug_report.md&title=$title"
        elif [[ "$report_type" == "feature" ]]; then
            url="$url?template=feature_request.md&title=$title"
        fi
        
        # Open browser if available
        if command -v xdg-open &> /dev/null; then
            xdg-open "$url"
        elif command -v open &> /dev/null; then
            open "$url"
        else
            echo "Please open this URL to create an issue:"
            echo "$url"
        fi
    fi
}

# Check status of pending feedback
show_status() {
    echo -e "${BLUE}Feedback Submission Status${NC}"
    echo "==========================="
    echo
    
    local pending=0
    local submitted=0
    
    if [[ -d "$FEEDBACK_DIR" ]]; then
        pending=$(find "$FEEDBACK_DIR" -name "*.md" -type f 2>/dev/null | wc -l)
        submitted=$(find "$FEEDBACK_DIR" -name "*.md.submitted" -type f 2>/dev/null | wc -l)
    fi
    
    echo "Pending submissions: $pending"
    echo "Submitted: $submitted"
    echo
    
    if [[ $pending -gt 0 ]]; then
        echo -e "${YELLOW}Pending reports:${NC}"
        find "$FEEDBACK_DIR" -name "*.md" -type f -exec basename {} \;
        echo
        echo "Submit pending reports with:"
        echo "  life feedback submit-all"
    fi
}

# Submit all pending reports
submit_all() {
    echo -e "${BLUE}Submitting all pending feedback...${NC}"
    
    local count=0
    
    for report in "$FEEDBACK_DIR"/*.md; do
        if [[ -f "$report" ]]; then
            local report_type
            if grep -q "^## Bug Report" "$report"; then
                report_type="bug"
            elif grep -q "^## Feature Request" "$report"; then
                report_type="feature"
            else
                report_type="general"
            fi
            
            submit_report "$report" "$report_type"
            ((count++))
        fi
    done
    
    echo
    echo -e "${GREEN}✓ Submitted $count reports${NC}"
}

# Main function
main() {
    case "${1:-}" in
        bug)
            shift
            collect_bug_report "$@"
            ;;
        feature)
            shift
            collect_feature_request "$@"
            ;;
        general)
            shift
            collect_general_feedback "$@"
            ;;
        status)
            show_status
            ;;
        submit)
            if [[ -f "${2:-}" ]]; then
                # Detect type from file
                if grep -q "^## Bug Report" "$2"; then
                    submit_report "$2" "bug"
                elif grep -q "^## Feature Request" "$2"; then
                    submit_report "$2" "feature"
                else
                    submit_report "$2" "general"
                fi
            else
                echo -e "${RED}Error: File not found: ${2:-}${NC}"
                exit 1
            fi
            ;;
        submit-all)
            submit_all
            ;;
        -h|--help|help)
            show_help
            ;;
        *)
            echo -e "${RED}Error: Unknown command${NC}"
            show_help
            exit 1
            ;;
    esac
}

# Run main
main "$@"
