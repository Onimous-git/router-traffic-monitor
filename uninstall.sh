#!/bin/sh
# ═══════════════════════════════════════════════════════════════
#  Router Traffic Monitor — Uninstaller
#  GitHub: https://github.com/Onimous-git/router-traffic-monitor
# ═══════════════════════════════════════════════════════════════

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { printf "  ${GREEN}✓${NC} %s\n" "$1"; }
fail() { printf "  ${RED}✗${NC} %s\n" "$1"; }
warn() { printf "  ${YELLOW}!${NC} %s\n" "$1"; }
info() { printf "  ${CYAN}→${NC} %s\n" "$1"; }

clear
echo ""
printf "${BOLD}${CYAN}"
echo "  ╔═══════════════════════════════════════════════════╗"
echo "  ║     Router Traffic Monitor — Uninstaller          ║"
echo "  ╚═══════════════════════════════════════════════════╝"
printf "${NC}"
echo ""
printf "  ${BOLD}This will remove all installed files.${NC}\n"
echo ""
printf "  Are you sure? (y/n): " >/dev/tty
read -r CONFIRM </dev/tty
[ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ] || { echo "  Aborted."; exit 0; }
echo ""

# Remove CGI
if [ -f /www/cgi-bin/traffic.cgi ]; then
    rm -f /www/cgi-bin/traffic.cgi
    ok "Removed: /www/cgi-bin/traffic.cgi"
else
    warn "Not found: /www/cgi-bin/traffic.cgi"
fi

# Remove nft table file
if [ -f /etc/nft-acct.nft ]; then
    rm -f /etc/nft-acct.nft
    ok "Removed: /etc/nft-acct.nft"
else
    warn "Not found: /etc/nft-acct.nft"
fi

# Remove hotplug script
if [ -f /etc/hotplug.d/iface/99-acct ]; then
    rm -f /etc/hotplug.d/iface/99-acct
    ok "Removed: /etc/hotplug.d/iface/99-acct"
else
    warn "Not found: /etc/hotplug.d/iface/99-acct"
fi

# Unload nft table from memory
if nft list table ip acct >/dev/null 2>&1; then
    nft delete table ip acct
    ok "nft acct table unloaded from memory"
else
    warn "nft acct table was not loaded"
fi

# Verify firewall still intact
echo ""
if nft list ruleset | grep -q "masquerade"; then
    ok "Firewall masquerade intact — internet working"
else
    warn "Masquerade not found — check your firewall"
fi

echo ""
printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "${GREEN}${BOLD}  Uninstall complete.${NC}\n"
printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
echo ""
