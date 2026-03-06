#!/bin/bash
# Firefox Hardened Integration Test Script
# Tests that Firefox is properly configured with privacy policies and extensions
#
# Usage:
#   ./tests/firefox/firefox_hardened_tests.sh [--container]
#
# Options:
#   --container  Run inside a container (skips GUI tests)

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Helper functions
pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    ((TESTS_PASSED++))
}

fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    ((TESTS_FAILED++))
}

skip() {
    echo -e "${YELLOW}○ SKIP${NC}: $1"
    ((TESTS_SKIPPED++))
}

section() {
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  $1${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
}

# ============================================================================
# PHASE 1: File Existence Tests
# ============================================================================

section "Phase 1: File Existence Tests"

# Test 1.1: Firefox binary exists
if command -v firefox &> /dev/null; then
    pass "Firefox binary exists at $(command -v firefox)"
else
    fail "Firefox binary not found in PATH"
fi

# Test 1.2: Enterprise policies file exists
if [[ -f "/etc/firefox/policies/policies.json" ]]; then
    pass "Enterprise policies file exists at /etc/firefox/policies/policies.json"
else
    fail "Enterprise policies file not found at /etc/firefox/policies/policies.json"
fi

# Test 1.3: uBlock Origin extension exists
if [[ -f "/usr/lib/firefox/distribution/extensions/uBlock0@raymondhill.net.xpi" ]]; then
    pass "uBlock Origin extension exists"
    EXT_SIZE=$(stat -c%s "/usr/lib/firefox/distribution/extensions/uBlock0@raymondhill.net.xpi" 2>/dev/null || stat -f%z "/usr/lib/firefox/distribution/extensions/uBlock0@raymondhill.net.xpi")
    if [[ $EXT_SIZE -gt 1000000 ]]; then
        pass "uBlock Origin extension size is valid ($(($EXT_SIZE / 1024)) KB)"
    else
        fail "uBlock Origin extension seems too small ($(($EXT_SIZE / 1024)) KB)"
    fi
else
    fail "uBlock Origin extension not found"
fi

# Test 1.4: Profile template files exist
if [[ -f "/etc/skel/.mozilla/firefox/profiles.ini" ]]; then
    pass "Firefox profiles.ini template exists"
else
    fail "Firefox profiles.ini template not found"
fi

if [[ -f "/etc/skel/.mozilla/firefox/lifeos.default/user.js" ]]; then
    pass "Firefox user.js template exists"
else
    fail "Firefox user.js template not found"
fi

if [[ -f "/etc/skel/.mozilla/firefox/lifeos.default/chrome/userChrome.css" ]]; then
    pass "Firefox userChrome.css template exists"
else
    fail "Firefox userChrome.css template not found"
fi

# Test 1.5: Wayland environment script exists
if [[ -f "/etc/profile.d/firefox-wayland.sh" ]]; then
    pass "Firefox Wayland environment script exists"
    if grep -q "MOZ_ENABLE_WAYLAND=1" "/etc/profile.d/firefox-wayland.sh"; then
        pass "MOZ_ENABLE_WAYLAND is set in environment script"
    else
        fail "MOZ_ENABLE_WAYLAND not found in environment script"
    fi
else
    fail "Firefox Wayland environment script not found"
fi

# Test 1.6: Desktop entry exists
if [[ -f "/usr/share/applications/firefox-lifeos.desktop" ]]; then
    pass "Firefox LifeOS desktop entry exists"
else
    fail "Firefox LifeOS desktop entry not found"
fi

# ============================================================================
# PHASE 2: Policy Content Tests
# ============================================================================

section "Phase 2: Policy Content Tests"

POLICIES_FILE="/etc/firefox/policies/policies.json"

if [[ -f "$POLICIES_FILE" ]]; then
    # Test 2.1: Valid JSON
    if python3 -c "import json; json.load(open('$POLICIES_FILE'))" 2>/dev/null; then
        pass "policies.json is valid JSON"
    else
        fail "policies.json is not valid JSON"
    fi
    
    # Test 2.2: Telemetry disabled
    if grep -q '"DisableTelemetry": true' "$POLICIES_FILE"; then
        pass "Telemetry is disabled"
    else
        fail "Telemetry is not disabled"
    fi
    
    # Test 2.3: Pocket disabled
    if grep -q '"DisablePocket": true' "$POLICIES_FILE"; then
        pass "Pocket is disabled"
    else
        fail "Pocket is not disabled"
    fi
    
    # Test 2.4: Firefox Studies disabled
    if grep -q '"DisableFirefoxStudies": true' "$POLICIES_FILE"; then
        pass "Firefox Studies is disabled"
    else
        fail "Firefox Studies is not disabled"
    fi
    
    # Test 2.5: Firefox Accounts disabled
    if grep -q '"DisableFirefoxAccounts": true' "$POLICIES_FILE"; then
        pass "Firefox Accounts is disabled"
    else
        fail "Firefox Accounts is not disabled"
    fi
    
    # Test 2.6: Form history disabled
    if grep -q '"DisableFormHistory": true' "$POLICIES_FILE"; then
        pass "Form history is disabled"
    else
        fail "Form history is not disabled"
    fi
    
    # Test 2.7: Default browser check disabled
    if grep -q '"DontCheckDefaultBrowser": true' "$POLICIES_FILE"; then
        pass "Default browser check is disabled"
    else
        fail "Default browser check is not disabled"
    fi
    
    # Test 2.8: First run page override
    if grep -q '"OverrideFirstRunPage": ""' "$POLICIES_FILE"; then
        pass "First run page is overridden (empty)"
    else
        fail "First run page is not overridden"
    fi
    
    # Test 2.9: Tracking protection enabled
    if grep -q '"EnableTrackingProtection"' "$POLICIES_FILE"; then
        pass "Tracking protection is configured"
    else
        fail "Tracking protection is not configured"
    fi
    
    # Test 2.10: uBlock Origin extension is configured
    if grep -q 'uBlock0@raymondhill.net' "$POLICIES_FILE"; then
        pass "uBlock Origin is configured in policies"
    else
        fail "uBlock Origin is not configured in policies"
    fi
    
    # Test 2.11: Homepage is blank
    if grep -q '"URL": "about:blank"' "$POLICIES_FILE"; then
        pass "Homepage is set to about:blank"
    else
        fail "Homepage is not set to about:blank"
    fi
    
    # Test 2.12: NewTabPage disabled
    if grep -q '"NewTabPage": false' "$POLICIES_FILE"; then
        pass "NewTabPage is disabled"
    else
        fail "NewTabPage is not disabled"
    fi
    
    # Test 2.13: User messaging silenced
    if grep -q '"SkipOnboarding": true' "$POLICIES_FILE"; then
        pass "User onboarding is skipped"
    else
        fail "User onboarding is not skipped"
    fi
    
    # Test 2.14: Search engines configured
    if grep -q '"Default": "DuckDuckGo"' "$POLICIES_FILE"; then
        pass "Default search engine is DuckDuckGo"
    else
        fail "Default search engine is not DuckDuckGo"
    fi
fi

# ============================================================================
# PHASE 3: User Preferences Tests
# ============================================================================

section "Phase 3: User Preferences Tests"

USER_JS="/etc/skel/.mozilla/firefox/lifeos.default/user.js"

if [[ -f "$USER_JS" ]]; then
    # Test 3.1: Wayland preferences
    if grep -q 'widget.wayland' "$USER_JS" || grep -q 'media.ffmpeg.vaapi' "$USER_JS"; then
        pass "Wayland/VA-API preferences are set"
    else
        fail "Wayland/VA-API preferences are not set"
    fi
    
    # Test 3.2: Privacy preferences
    if grep -q 'privacy.resistFingerprinting' "$USER_JS"; then
        pass "Fingerprinting resistance is configured"
    else
        fail "Fingerprinting resistance is not configured"
    fi
    
    # Test 3.3: DNS over HTTPS
    if grep -q 'network.trr.mode' "$USER_JS"; then
        pass "DNS over HTTPS is configured"
    else
        fail "DNS over HTTPS is not configured"
    fi
    
    # Test 3.4: Hardware acceleration
    if grep -q 'layers.acceleration' "$USER_JS"; then
        pass "Hardware acceleration is configured"
    else
        fail "Hardware acceleration is not configured"
    fi
    
    # Test 3.5: Dark theme preference
    if grep -q 'prefers-color-scheme.content-override' "$USER_JS"; then
        pass "Dark theme preference is set"
    else
        fail "Dark theme preference is not set"
    fi
    
    # Test 3.6: WebRTC leak protection
    if grep -q 'media.peerconnection.ice.default_address_only' "$USER_JS"; then
        pass "WebRTC leak protection is configured"
    else
        fail "WebRTC leak protection is not configured"
    fi
fi

# ============================================================================
# PHASE 4: Visual Theme Tests
# ============================================================================

section "Phase 4: Visual Theme Tests"

USER_CHROME="/etc/skel/.mozilla/firefox/lifeos.default/chrome/userChrome.css"

if [[ -f "$USER_CHROME" ]]; then
    # Test 4.1: LifeOS brand colors are defined
    if grep -q '#0f4c75' "$USER_CHROME" && grep -q '#3282b8' "$USER_CHROME"; then
        pass "LifeOS brand colors (primary, accent) are defined"
    else
        fail "LifeOS brand colors are not properly defined"
    fi
    
    # Test 4.2: Background color matches LifeOS
    if grep -q '#1a1a2e' "$USER_CHROME"; then
        pass "LifeOS background color is defined"
    else
        fail "LifeOS background color is not defined"
    fi
    
    # Test 4.3: Tab bar styling exists
    if grep -q '#TabsToolbar' "$USER_CHROME"; then
        pass "Tab bar styling exists"
    else
        fail "Tab bar styling is missing"
    fi
    
    # Test 4.4: URL bar styling exists
    if grep -q '#urlbar' "$USER_CHROME"; then
        pass "URL bar styling exists"
    else
        fail "URL bar styling is missing"
    fi
    
    # Test 4.5: Menu styling exists
    if grep -q 'menupopup' "$USER_CHROME"; then
        pass "Menu styling exists"
    else
        fail "Menu styling is missing"
    fi
fi

# ============================================================================
# PHASE 5: Desktop Entry Tests
# ============================================================================

section "Phase 5: Desktop Entry Tests"

DESKTOP_FILE="/usr/share/applications/firefox-lifeos.desktop"

if [[ -f "$DESKTOP_FILE" ]]; then
    # Test 5.1: Valid desktop entry
    if grep -q '\[Desktop Entry\]' "$DESKTOP_FILE"; then
        pass "Desktop entry has valid header"
    else
        fail "Desktop entry is missing valid header"
    fi
    
    # Test 5.2: Name is set
    if grep -q '^Name=' "$DESKTOP_FILE"; then
        pass "Desktop entry has Name set"
    else
        fail "Desktop entry is missing Name"
    fi
    
    # Test 5.3: Exec includes Wayland
    if grep -q 'Exec=.*firefox' "$DESKTOP_FILE"; then
        pass "Desktop entry has Exec command"
    else
        fail "Desktop entry is missing Exec command"
    fi
    
    # Test 5.4: Icon is set
    if grep -q '^Icon=' "$DESKTOP_FILE"; then
        pass "Desktop entry has Icon set"
    else
        fail "Desktop entry is missing Icon"
    fi
    
    # Test 5.5: Categories include WebBrowser
    if grep -q 'Categories=.*WebBrowser' "$DESKTOP_FILE"; then
        pass "Desktop entry has WebBrowser category"
    else
        fail "Desktop entry is missing WebBrowser category"
    fi
    
    # Test 5.6: StartupWMClass is set for Wayland
    if grep -q 'StartupWMClass=' "$DESKTOP_FILE"; then
        pass "Desktop entry has StartupWMClass set"
    else
        fail "Desktop entry is missing StartupWMClass"
    fi
fi

# ============================================================================
# SUMMARY
# ============================================================================

section "Test Summary"

TOTAL=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))
echo ""
echo "Total tests: $TOTAL"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
echo -e "${YELLOW}Skipped: $TESTS_SKIPPED${NC}"
echo ""

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed. Please review the output above.${NC}"
    exit 1
fi
