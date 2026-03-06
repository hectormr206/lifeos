#!/bin/bash
#===============================================================================
# LifeOS Night Mode Validation Script
#===============================================================================
# Validates that Night Mode reduces eye strain during extended sessions (3+ hours)
# This is a human-in-the-loop checklist - cannot be fully automated.
#
# Usage: ./scripts/validate-night-mode.sh [--session-start | --session-end]
#===============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Configuration
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/lifeos"
VALIDATION_DIR="$CONFIG_DIR/night-mode-validation"
SESSION_FILE="$VALIDATION_DIR/current-session.json"

# Ensure directories exist
mkdir -p "$VALIDATION_DIR"

# Show help
show_help() {
    cat << EOF
LifeOS Night Mode Validation

Validates that Night Mode (blue light reduction + warm color temperature) 
effectively reduces eye strain during extended work sessions (3+ hours).

This is a HUMAN-IN-THE-LOOP process - cannot be fully automated.

USAGE:
    ./scripts/validate-night-mode.sh <COMMAND>

COMMANDS:
    start               Begin a new validation session
    check               Mid-session checkpoint (every 30-60 min)
    end                 End validation session and generate report
    status              Show current session status
    report              Generate validation report from last session
    checklist           Display the full validation checklist

OPTIONS:
    -h, --help          Show this help message

EXAMPLES:
    # Start a 3+ hour validation session
    ./scripts/validate-night-mode.sh start

    # Check in during session
    ./scripts/validate-night-mode.sh check

    # End session and generate report
    ./scripts/validate-night-mode.sh end

REQUIREMENTS:
    - Night Mode enabled (life focus night)
    - Session duration: minimum 3 hours
    - Checklist responses: honest self-assessment

VALIDATION CRITERIA:
    ✓ Eye comfort score ≥ 7/10 after 3 hours
    ✓ No headache or eye strain reported
    ✓ Color accuracy acceptable for work
    ✓ Sleep quality not negatively affected
    ✓ Productivity maintained or improved
EOF
}

# Display full validation checklist
display_checklist() {
    cat << EOF
$(echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════╗${NC})
$(echo -e "${CYAN}║          NIGHT MODE VALIDATION CHECKLIST (3+ Hour Session)           ║${NC})
$(echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════╝${NC})

$(echo -e "${BLUE}═══ PRE-SESSION CHECKLIST ═══${NC})
□ Night Mode enabled (life focus night or auto)
□ Room lighting appropriate (not too bright/dark)
□ Screen brightness at comfortable level
□ Baseline eye comfort recorded
□ Start time noted

$(echo -e "${BLUE}═══ MID-SESSION CHECKLIST (Every 30-60 min) ═══${NC})
□ Eye comfort level (1-10): ____
□ Any eye strain noticed? (Y/N): ____
□ Any headache? (Y/N): ____
□ Screen readability acceptable? (Y/N): ____
□ Colors distinguishable? (Y/N): ____
□ Time of checkpoint: ____

$(echo -e "${BLUE}═══ POST-SESSION CHECKLIST (After 3+ hours) ═══${NC})
□ Total session duration: ____ hours
□ Final eye comfort level (1-10): ____
□ Eye strain during session? (Y/N): ____
□ Headache during session? (Y/N): ____
□ Dry eyes? (Y/N): ____
□ Difficulty focusing? (Y/N): ____
□ Sleep quality same night (1-10): ____
□ Work productivity maintained? (Y/N): ____
□ Would use Night Mode again? (Y/N): ____

$(echo -e "${BLUE}═══ COLOR ACCURACY ASSESSMENT ═══${NC})
□ Code syntax highlighting readable? (Y/N): ____
□ Images/photos acceptable? (Y/N): ____
□ UI elements distinguishable? (Y/N): ____
□ Text contrast sufficient? (Y/N): ____

$(echo -e "${BLUE}═══ VALIDATION RESULT ═══${NC})
Pass Criteria (all must be met):
  ✓ Final eye comfort ≥ 7/10
  ✓ No headache reported
  ✓ No significant eye strain
  ✓ Sleep quality ≥ 6/10
  ✓ Would use again = Yes

Result: PASS / FAIL

$(echo -e "${BLUE}═══ NOTES ═══${NC})
_____________________________________________
_____________________________________________
_____________________________________________

$(echo -e "${MAGENTA}Validator: ________________  Date: ________________${NC})
EOF
}

# Start a new validation session
start_session() {
    echo -e "${BLUE}Starting Night Mode Validation Session${NC}"
    echo "======================================"
    echo

    # Check if session already in progress
    if [[ -f "$SESSION_FILE" ]]; then
        echo -e "${YELLOW}Warning: A session may already be in progress.${NC}"
        echo -n "Overwrite and start new session? [y/N] "
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
        fi
    fi

    # Pre-session checklist
    echo -e "${CYAN}Pre-Session Checklist:${NC}"
    echo

    # Check Night Mode status
    echo -n "Is Night Mode enabled? [y/N] "
    read -r night_mode
    if [[ ! "$night_mode" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Please enable Night Mode first: life focus night${NC}"
        exit 1
    fi

    echo -n "Is room lighting appropriate? [y/N] "
    read -r room_light

    echo -n "Is screen brightness comfortable? [y/N] "
    read -r brightness

    echo -n "Baseline eye comfort level (1-10): "
    read -r baseline_comfort

    # Create session file
    local start_time=$(date -Iseconds)
    local session_id="session-$(date +%Y%m%d-%H%M%S)"

    cat > "$SESSION_FILE" << EOF
{
    "session_id": "$session_id",
    "start_time": "$start_time",
    "baseline_comfort": $baseline_comfort,
    "night_mode_enabled": true,
    "room_lighting_ok": $([[ "$room_light" =~ ^[Yy]$ ]] && echo 'true' || echo 'false'),
    "brightness_ok": $([[ "$brightness" =~ ^[Yy]$ ]] && echo 'true' || echo 'false'),
    "checkpoints": [],
    "end_time": null,
    "final_comfort": null,
    "validation_result": null
}
EOF

    echo
    echo -e "${GREEN}✓ Validation session started${NC}"
    echo "  Session ID: $session_id"
    echo "  Start time: $start_time"
    echo
    echo -e "${CYAN}Next steps:${NC}"
    echo "  1. Work normally for at least 3 hours"
    echo "  2. Run './scripts/validate-night-mode.sh check' every 30-60 minutes"
    echo "  3. Run './scripts/validate-night-mode.sh end' when done"
    echo
    echo -e "${YELLOW}Minimum session duration: 3 hours${NC}"
}

# Mid-session checkpoint
checkpoint() {
    if [[ ! -f "$SESSION_FILE" ]]; then
        echo -e "${RED}Error: No active session. Run 'start' first.${NC}"
        exit 1
    fi

    echo -e "${BLUE}Mid-Session Checkpoint${NC}"
    echo "====================="
    echo

    # Get current session info
    local start_time=$(jq -r '.start_time' "$SESSION_FILE")
    local elapsed=$(($(date +%s) - $(date -d "$start_time" +%s 2>/dev/null || echo "0")))
    local hours=$((elapsed / 3600))
    local minutes=$(((elapsed % 3600) / 60))

    echo "Session duration: ${hours}h ${minutes}m"
    echo

    # Checkpoint questions
    echo -n "Current eye comfort level (1-10): "
    read -r comfort

    echo -n "Any eye strain? [y/N] "
    read -r strain
    local has_strain=$([[ "$strain" =~ ^[Yy]$ ]] && echo 'true' || echo 'false')

    echo -n "Any headache? [y/N] "
    read -r headache
    local has_headache=$([[ "$headache" =~ ^[Yy]$ ]] && echo 'true' || echo 'false')

    echo -n "Screen readability OK? [y/N] "
    read -r readability
    local readability_ok=$([[ "$readability" =~ ^[Yy]$ ]] && echo 'true' || echo 'false')

    echo -n "Colors distinguishable? [y/N] "
    read -r colors
    local colors_ok=$([[ "$colors" =~ ^[Yy]$ ]] && echo 'true' || echo 'false')

    # Add checkpoint to session
    local checkpoint_time=$(date -Iseconds)
    local checkpoint_json=$(cat << EOF
{
    "time": "$checkpoint_time",
    "elapsed_minutes": $((elapsed / 60)),
    "comfort": $comfort,
    "eye_strain": $has_strain,
    "headache": $has_headache,
    "readability_ok": $readability_ok,
    "colors_ok": $colors_ok
}
EOF
)

    # Update session file
    local tmp_file=$(mktemp)
    jq ".checkpoints += [$checkpoint_json]" "$SESSION_FILE" > "$tmp_file" && mv "$tmp_file" "$SESSION_FILE"

    echo
    echo -e "${GREEN}✓ Checkpoint recorded at ${checkpoint_time}${NC}"
    echo

    # Show progress
    local checkpoint_count=$(jq '.checkpoints | length' "$SESSION_FILE")
    echo "Total checkpoints: $checkpoint_count"

    if [[ $elapsed -lt 10800 ]]; then
        local remaining=$((10800 - elapsed))
        echo -e "${YELLOW}Time remaining for minimum duration: $((remaining / 3600))h $(((remaining % 3600) / 60))m${NC}"
    else
        echo -e "${GREEN}Minimum session duration met! You can end the session anytime.${NC}"
    fi
}

# End validation session
end_session() {
    if [[ ! -f "$SESSION_FILE" ]]; then
        echo -e "${RED}Error: No active session. Run 'start' first.${NC}"
        exit 1
    fi

    echo -e "${BLUE}Ending Night Mode Validation Session${NC}"
    echo "===================================="
    echo

    # Get session info
    local start_time=$(jq -r '.start_time' "$SESSION_FILE")
    local elapsed=$(($(date +%s) - $(date -d "$start_time" +%s 2>/dev/null || echo "0")))
    local hours=$((elapsed / 3600))
    local minutes=$(((elapsed % 3600) / 60))

    echo "Session duration: ${hours}h ${minutes}m"

    if [[ $elapsed -lt 10800 ]]; then
        echo -e "${YELLOW}Warning: Session is less than 3 hours (${hours}h ${minutes}m)${NC}"
        echo -n "Continue anyway? [y/N] "
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Session continues. Run 'end' again when ready."
            exit 0
        fi
    fi

    echo
    echo -e "${CYAN}Post-Session Assessment:${NC}"
    echo

    echo -n "Final eye comfort level (1-10): "
    read -r final_comfort

    echo -n "Did you experience eye strain? [y/N] "
    read -r strain
    local had_strain=$([[ "$strain" =~ ^[Yy]$ ]] && echo 'true' || echo 'false')

    echo -n "Did you experience headache? [y/N] "
    read -r headache
    local had_headache=$([[ "$headache" =~ ^[Yy]$ ]] && echo 'true' || echo 'false')

    echo -n "Dry eyes? [y/N] "
    read -r dry_eyes
    local had_dry_eyes=$([[ "$dry_eyes" =~ ^[Yy]$ ]] && echo 'true' || echo 'false')

    echo -n "Difficulty focusing? [y/N] "
    read -r focus
    local had_focus_issues=$([[ "$focus" =~ ^[Yy]$ ]] && echo 'true' || echo 'false')

    echo -n "Sleep quality same night (1-10, or 'n/a'): "
    read -r sleep_quality
    local sleep_num=$([[ "$sleep_quality" == "n/a" ]] && echo 'null' || echo "$sleep_quality")

    echo -n "Work productivity maintained? [y/N] "
    read -r productivity
    local productivity_ok=$([[ "$productivity" =~ ^[Yy]$ ]] && echo 'true' || echo 'false')

    echo -n "Would use Night Mode again? [y/N] "
    read -r use_again
    local would_use_again=$([[ "$use_again" =~ ^[Yy]$ ]] && echo 'true' || echo 'false')

    # Color accuracy assessment
    echo
    echo -e "${CYAN}Color Accuracy Assessment:${NC}"
    echo

    echo -n "Code syntax highlighting readable? [y/N] "
    read -r syntax
    local syntax_ok=$([[ "$syntax" =~ ^[Yy]$ ]] && echo 'true' || echo 'false')

    echo -n "Images/photos acceptable? [y/N] "
    read -r images
    local images_ok=$([[ "$images" =~ ^[Yy]$ ]] && echo 'true' || echo 'false')

    echo -n "UI elements distinguishable? [y/N] "
    read -r ui
    local ui_ok=$([[ "$ui" =~ ^[Yy]$ ]] && echo 'true' || echo 'false')

    echo -n "Text contrast sufficient? [y/N] "
    read -r contrast
    local contrast_ok=$([[ "$contrast" =~ ^[Yy]$ ]] && echo 'true' || echo 'false')

    # Determine validation result
    local pass=true
    [[ $final_comfort -lt 7 ]] && pass=false
    $had_headache && pass=false
    $had_strain && pass=false
    [[ "$sleep_quality" != "n/a" && $sleep_quality -lt 6 ]] && pass=false
    ! $would_use_again && pass=false

    local validation_result="PASS"
    $pass || validation_result="FAIL"

    # Update session file
    local end_time=$(date -Iseconds)
    local session_id=$(jq -r '.session_id' "$SESSION_FILE")
    local baseline=$(jq -r '.baseline_comfort' "$SESSION_FILE")

    local tmp_file=$(mktemp)
    jq --arg end "$end_time" \
       --argjson comfort "$final_comfort" \
       --arg result "$validation_result" \
       '. + {
           "end_time": $end,
           "final_comfort": $comfort,
           "validation_result": $result,
           "had_eye_strain": '"$had_strain"',
           "had_headache": '"$had_headache"',
           "had_dry_eyes": '"$had_dry_eyes"',
           "had_focus_issues": '"$had_focus_issues"',
           "sleep_quality": '"$sleep_num"',
           "productivity_maintained": '"$productivity_ok"',
           "would_use_again": '"$would_use_again"',
           "color_accuracy": {
               "syntax_ok": '"$syntax_ok"',
               "images_ok": '"$images_ok"',
               "ui_ok": '"$ui_ok"',
               "contrast_ok": '"$contrast_ok"'
           }
       }' "$SESSION_FILE" > "$tmp_file" && mv "$tmp_file" "$SESSION_FILE"

    # Archive session
    cp "$SESSION_FILE" "$VALIDATION_DIR/${session_id}.json"

    echo
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    if $pass; then
        echo -e "${GREEN}  ✓ VALIDATION PASSED${NC}"
    else
        echo -e "${RED}  ✗ VALIDATION FAILED${NC}"
    fi
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo
    echo "Session Summary:"
    echo "  Duration: ${hours}h ${minutes}m"
    echo "  Baseline comfort: $baseline/10"
    echo "  Final comfort: $final_comfort/10"
    echo "  Result: $validation_result"
    echo
    echo "Session archived to: $VALIDATION_DIR/${session_id}.json"
    echo
    echo "Generate full report with: ./scripts/validate-night-mode.sh report"
}

# Show current session status
show_status() {
    if [[ ! -f "$SESSION_FILE" ]]; then
        echo -e "${YELLOW}No active validation session${NC}"
        echo "Start a new session with: ./scripts/validate-night-mode.sh start"
        exit 0
    fi

    local start_time=$(jq -r '.start_time' "$SESSION_FILE")
    local session_id=$(jq -r '.session_id' "$SESSION_FILE")
    local baseline=$(jq -r '.baseline_comfort' "$SESSION_FILE")
    local checkpoints=$(jq '.checkpoints | length' "$SESSION_FILE")
    local elapsed=$(($(date +%s) - $(date -d "$start_time" +%s 2>/dev/null || echo "0")))
    local hours=$((elapsed / 3600))
    local minutes=$(((elapsed % 3600) / 60))

    echo -e "${BLUE}Night Mode Validation Session Status${NC}"
    echo "===================================="
    echo
    echo "Session ID: $session_id"
    echo "Started: $start_time"
    echo "Duration: ${hours}h ${minutes}m"
    echo "Baseline comfort: $baseline/10"
    echo "Checkpoints recorded: $checkpoints"
    echo

    if [[ $elapsed -lt 10800 ]]; then
        local remaining=$((10800 - elapsed))
        echo -e "${YELLOW}Minimum duration not yet met ($((remaining / 3600))h $(((remaining % 3600) / 60))m remaining)${NC}"
    else
        echo -e "${GREEN}✓ Minimum duration met - ready to end session${NC}"
    fi

    # Show last checkpoint if exists
    if [[ $checkpoints -gt 0 ]]; then
        echo
        echo "Last checkpoint:"
        jq '.checkpoints[-1]' "$SESSION_FILE"
    fi
}

# Generate validation report
generate_report() {
    local latest_session=$(ls -t "$VALIDATION_DIR"/session-*.json 2>/dev/null | head -1)

    if [[ -z "$latest_session" ]]; then
        echo -e "${RED}Error: No completed sessions found${NC}"
        exit 1
    fi

    local session_id=$(jq -r '.session_id' "$latest_session")
    local start_time=$(jq -r '.start_time' "$latest_session")
    local end_time=$(jq -r '.end_time' "$latest_session")
    local baseline=$(jq -r '.baseline_comfort' "$latest_session")
    local final=$(jq -r '.final_comfort' "$latest_session")
    local result=$(jq -r '.validation_result' "$latest_session")
    local checkpoints=$(jq '.checkpoints | length' "$latest_session")

    # Calculate duration
    local duration=$(($(date -d "$end_time" +%s) - $(date -d "$start_time" +%s)))
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))

    local report_file="$VALIDATION_DIR/report-${session_id}.md"

    cat > "$report_file" << EOF
# Night Mode Validation Report

**Session ID:** $session_id  
**Generated:** $(date -Iseconds)  

## Session Overview

| Metric | Value |
|--------|-------|
| Start Time | $start_time |
| End Time | $end_time |
| Duration | ${hours}h ${minutes}m |
| Checkpoints | $checkpoints |
| Result | **$result** |

## Comfort Scores

| Measurement | Score |
|-------------|-------|
| Baseline (start) | $baseline/10 |
| Final (end) | $final/10 |
| Change | $((final - baseline)) |

## Validation Criteria

| Criterion | Required | Actual | Status |
|-----------|----------|--------|--------|
| Final comfort | ≥ 7/10 | $final/10 | $([[ $final -ge 7 ]] && echo '✓' || echo '✗') |
| No headache | Yes | $(jq -r '.had_headache' "$latest_session") | $(jq -r 'if .had_headache then "✗" else "✓" end' "$latest_session") |
| No eye strain | Yes | $(jq -r '.had_eye_strain' "$latest_session") | $(jq -r 'if .had_eye_strain then "✗" else "✓" end' "$latest_session") |
| Sleep quality | ≥ 6/10 | $(jq -r '.sleep_quality // "N/A"' "$latest_session") | $(jq -r 'if .sleep_quality == null then "—" elif .sleep_quality >= 6 then "✓" else "✗" end' "$latest_session") |
| Would use again | Yes | $(jq -r '.would_use_again' "$latest_session") | $(jq -r 'if .would_use_again then "✓" else "✗" end' "$latest_session") |

## Color Accuracy

| Aspect | Status |
|--------|--------|
| Syntax highlighting | $(jq -r 'if .color_accuracy.syntax_ok then "✓ OK" else "✗ Issues" end' "$latest_session") |
| Images/photos | $(jq -r 'if .color_accuracy.images_ok then "✓ OK" else "✗ Issues" end' "$latest_session") |
| UI elements | $(jq -r 'if .color_accuracy.ui_ok then "✓ OK" else "✗ Issues" end' "$latest_session") |
| Text contrast | $(jq -r 'if .color_accuracy.contrast_ok then "✓ OK" else "✗ Issues" end' "$latest_session") |

## Checkpoint History

$(jq -r '.checkpoints | to_entries | map("| \(.value.elapsed_minutes)m | \(.value.comfort)/10 | \(if .value.eye_strain then "Yes" else "No" end) | \(if .value.headache then "Yes" else "No" end) |") | join("\n")' "$latest_session")

| Elapsed | Comfort | Strain | Headache |
|---------|---------|--------|----------|
$(jq -r '.checkpoints | to_entries | map("| \(.value.elapsed_minutes)m | \(.value.comfort)/10 | \(if .value.eye_strain then "Yes" else "No" end) | \(if .value.headache then "Yes" else "No" end) |") | join("\n")' "$latest_session")

## Conclusion

**Validation Result: $result**

$(if [[ "$result" == "PASS" ]]; then
    echo "Night Mode successfully reduced eye strain during the extended session. The warm color temperature and blue light reduction maintained comfort levels while preserving sufficient color accuracy for work tasks."
else
    echo "Night Mode did not meet validation criteria. Review the failing criteria above and consider adjustments to color temperature or intensity settings."
fi)

---
*Report generated by LifeOS Night Mode Validation Script*
EOF

    echo -e "${GREEN}Report generated: $report_file${NC}"
    echo
    cat "$report_file"
}

# Main function
main() {
    case "${1:-}" in
        start)
            start_session
            ;;
        check|checkpoint)
            checkpoint
            ;;
        end)
            end_session
            ;;
        status)
            show_status
            ;;
        report)
            generate_report
            ;;
        checklist)
            display_checklist
            ;;
        -h|--help|help)
            show_help
            ;;
        *)
            echo -e "${RED}Error: Unknown command '${1:-}'${NC}"
            show_help
            exit 1
            ;;
    esac
}

# Run main
main "$@"
