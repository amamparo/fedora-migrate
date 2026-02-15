#!/usr/bin/env bash
# =============================================================================
# verify.sh — Post-install verification
# Run after the playbook completes and you've rebooted.
# Checks everything that can be checked programmatically.
# =============================================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

pass() { echo -e "  ${GREEN}✓${NC} $*"; ((PASS++)); }
fail() { echo -e "  ${RED}✗${NC} $*"; ((FAIL++)); }
skip() { echo -e "  ${YELLOW}–${NC} $*"; ((WARN++)); }
section() { echo -e "\n${BOLD}${GREEN}━━━ $* ━━━${NC}"; }

has_cmd() { command -v "$1" &>/dev/null; }

check() {
    local description="$1"
    shift
    if "$@" &>/dev/null; then
        pass "$description"
    else
        fail "$description"
    fi
}

# -- System basics -----------------------------------------------------------

section "System"

check "Shell is zsh" test "$(basename "$SHELL")" = "zsh"
check "Network connectivity" ping -c1 -W3 8.8.8.8
check "DNS resolution" ping -c1 -W3 google.com

if has_cmd timedatectl; then
    tz="$(timedatectl show -p Timezone --value 2>/dev/null)"
    [[ -n "$tz" ]] && pass "Timezone: $tz" || fail "Timezone not set"
fi

# -- Repos -------------------------------------------------------------------

section "Repositories"

if dnf repolist 2>/dev/null | grep -q rpmfusion-free; then
    pass "RPM Fusion free enabled"
else
    skip "RPM Fusion free not enabled (may be expected)"
fi

if dnf repolist 2>/dev/null | grep -q rpmfusion-nonfree; then
    pass "RPM Fusion nonfree enabled"
else
    skip "RPM Fusion nonfree not enabled (may be expected)"
fi

copr_count="$(compgen -G '/etc/yum.repos.d/_copr[_:]*' 2>/dev/null | wc -l)"
[[ "$copr_count" -gt 0 ]] && pass "$copr_count COPR repo(s)" || skip "No COPR repos"

if has_cmd flatpak; then
    flatpak_count="$(flatpak list --app 2>/dev/null | wc -l)"
    pass "$flatpak_count Flatpak app(s) installed"
else
    skip "Flatpak not installed"
fi

# -- Shell -------------------------------------------------------------------

section "Shell"

# Test zsh starts clean (no errors on stderr)
zsh_errors="$(zsh -l -c 'echo ok' 2>&1 >/dev/null)" || true
if [[ -z "$zsh_errors" ]]; then
    pass "zsh starts without errors"
else
    fail "zsh startup errors: $(echo "$zsh_errors" | head -1)"
fi

# Check plugin manager
if [[ -d "$HOME/.oh-my-zsh" ]]; then
    pass "oh-my-zsh installed"
elif [[ -d "$HOME/.local/share/zinit" ]]; then
    pass "zinit installed"
elif [[ -d "$HOME/.antidote" ]]; then
    pass "antidote installed"
fi

# Check PATH includes user script dirs
echo "$PATH" | grep -q "$HOME/bin\|$HOME/.local/bin" && \
    pass "~/bin or ~/.local/bin in PATH" || \
    skip "~/bin / ~/.local/bin not in PATH"

# GPG keys
if has_cmd gpg; then
    gpg_count="$(gpg --list-keys --keyid-format long 2>/dev/null | grep -c '^pub' || echo 0)"
    [[ "$gpg_count" -gt 0 ]] && pass "$gpg_count GPG public key(s)" || skip "No GPG keys"
fi

# SSH authorized_keys
[[ -f "$HOME/.ssh/authorized_keys" ]] && pass "SSH authorized_keys present" || skip "No SSH authorized_keys"

# -- Desktop -----------------------------------------------------------------

section "KDE Desktop"

if has_cmd plasmashell; then
    plasma_ver="$(plasmashell --version 2>/dev/null | awk '{print $NF}')"
    pass "Plasma running (v$plasma_ver)"
else
    skip "plasmashell not found"
fi

# Check wallpaper exists
if [[ -d "$HOME/.local/share/wallpapers" ]]; then
    wp_count="$(find "$HOME/.local/share/wallpapers" -type f 2>/dev/null | wc -l)"
    [[ "$wp_count" -gt 0 ]] && pass "$wp_count wallpaper file(s)" || skip "No wallpapers"
fi

# Check fonts
if [[ -d "$HOME/.local/share/fonts" ]]; then
    font_count="$(find "$HOME/.local/share/fonts" -type f 2>/dev/null | wc -l)"
    [[ "$font_count" -gt 0 ]] && pass "$font_count user font(s)" || skip "No user fonts"
fi

# Konsole profiles
if [[ -d "$HOME/.local/share/konsole" ]]; then
    konsole_count="$(ls "$HOME/.local/share/konsole/"*.profile 2>/dev/null | wc -l)"
    [[ "$konsole_count" -gt 0 ]] && pass "$konsole_count Konsole profile(s)" || skip "No Konsole profiles"
fi

# KScreen display profiles
if [[ -d "$HOME/.local/share/kscreen" ]]; then
    kscreen_count="$(find "$HOME/.local/share/kscreen" -type f 2>/dev/null | wc -l)"
    [[ "$kscreen_count" -gt 0 ]] && pass "KScreen display profiles present" || skip "No KScreen profiles"
fi

# MIME default applications
[[ -f "$HOME/.config/mimeapps.list" ]] && pass "MIME default applications configured" || skip "No mimeapps.list"

# -- Audio -------------------------------------------------------------------

section "Audio"

if has_cmd pw-cli; then
    if pw-cli info 0 &>/dev/null; then
        pass "PipeWire running"
    else
        fail "PipeWire not responding"
    fi
else
    skip "PipeWire not installed"
fi

# Realtime scheduling
rt_limit="$(ulimit -r 2>/dev/null || echo 0)"
if [[ "$rt_limit" -gt 0 ]]; then
    pass "Realtime scheduling available (priority $rt_limit)"
else
    skip "No realtime scheduling (may be expected)"
fi

# -- Dev tools ---------------------------------------------------------------

section "Dev Tools"

has_cmd git && pass "git $(git --version | awk '{print $3}')" || skip "git not found"
has_cmd python3 && pass "python3 $(python3 --version 2>&1 | awk '{print $2}')" || skip "python3 not found"
has_cmd node && pass "node $(node --version)" || skip "node not found"
has_cmd cargo && pass "cargo $(cargo --version | awk '{print $2}')" || skip "cargo not found"
has_cmd go && pass "go $(go version | awk '{print $3}')" || skip "go not found"
has_cmd docker && pass "docker available" || true
has_cmd podman && pass "podman available" || true

# VS Code extensions
for vsc_cmd in code code-oss codium; do
    if has_cmd "$vsc_cmd"; then
        ext_count="$("$vsc_cmd" --list-extensions 2>/dev/null | wc -l)"
        [[ "$ext_count" -gt 0 ]] && pass "$ext_count $vsc_cmd extension(s)" || skip "No $vsc_cmd extensions"
    fi
done

# -- Hardware ----------------------------------------------------------------

section "Hardware"

# Microcode
if journalctl -k --no-pager 2>/dev/null | grep -qi 'microcode.*updated\|microcode.*revision'; then
    pass "CPU microcode loaded"
else
    skip "No microcode update detected in dmesg"
fi

# GPU
if has_cmd glxinfo; then
    renderer="$(glxinfo 2>/dev/null | grep 'OpenGL renderer' | sed 's/.*: //')"
    [[ -n "$renderer" ]] && pass "GPU: $renderer" || fail "No OpenGL renderer"
else
    skip "glxinfo not available (install mesa-demos)"
fi

# Power management
if has_cmd powerprofilesctl; then
    pass "power-profiles-daemon active"
elif has_cmd tlp-stat; then
    pass "TLP active"
else
    skip "No power management detected"
fi

# Printers
if has_cmd lpstat; then
    printer_count="$(lpstat -p 2>/dev/null | grep -c 'printer' || echo 0)"
    [[ "$printer_count" -gt 0 ]] && pass "$printer_count printer(s) configured" || skip "No printers"
fi

# -- System extras -----------------------------------------------------------

section "System Extras"

# Crontab
if crontab -l &>/dev/null 2>&1; then
    cron_count="$(crontab -l 2>/dev/null | grep -cv '^\s*#\|^\s*$' || echo 0)"
    [[ "$cron_count" -gt 0 ]] && pass "$cron_count crontab entry/entries" || skip "Crontab empty"
else
    skip "No crontab"
fi

# Flatpak overrides
if [[ -d "$HOME/.local/share/flatpak/overrides" ]]; then
    override_count="$(ls "$HOME/.local/share/flatpak/overrides/" 2>/dev/null | wc -l)"
    [[ "$override_count" -gt 0 ]] && pass "$override_count Flatpak override(s)" || skip "No Flatpak overrides"
fi

# -- Firewall ----------------------------------------------------------------

section "Firewall"

if has_cmd firewall-cmd; then
    if firewall-cmd --state &>/dev/null; then
        services="$(firewall-cmd --list-services 2>/dev/null)"
        pass "firewalld running (services: $services)"
    else
        skip "firewalld installed but not running"
    fi
else
    skip "firewalld not installed"
fi

# -- Summary -----------------------------------------------------------------

echo ""
echo -e "${BOLD}━━━ Results ━━━${NC}"
echo -e "  ${GREEN}$PASS passed${NC}  ${RED}$FAIL failed${NC}  ${YELLOW}$WARN skipped${NC}"

if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo -e "  Re-run failed roles: ${BOLD}ansible-playbook site.yml --tags <role>${NC}"
fi

# Visual checks that can't be automated
echo ""
echo -e "${BOLD}Manual visual checks:${NC}"
echo "  - Plasma panels, widgets, wallpaper match source"
echo "  - Color scheme, icon theme, cursor theme correct"
echo "  - Window decorations and font rendering look right"
echo "  - SDDM login screen theme matches"

exit $FAIL
