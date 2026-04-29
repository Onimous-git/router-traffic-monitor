#!/bin/sh
# ═══════════════════════════════════════════════════════════════
#  Router Traffic Monitor — Installer
#  GitHub: https://github.com/Onimous-git/router-traffic-monitor
# ═══════════════════════════════════════════════════════════════

REPO="https://raw.githubusercontent.com/Onimous-git/router-traffic-monitor/main"
CGI_PATH="/www/cgi-bin/traffic.cgi"
NFT_PATH="/etc/nft-acct.nft"
HOTPLUG_PATH="/etc/hotplug.d/iface/99-acct"
MIN_FLASH_KB=200
MIN_RAM_MB=10
MIN_OPENWRT_MAJOR=21
MIN_OPENWRT_MINOR=02

# ── Colors ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { printf "  ${GREEN}✓${NC} %s\n" "$1"; }
fail() { printf "  ${RED}✗${NC} %s\n" "$1"; }
warn() { printf "  ${YELLOW}!${NC} %s\n" "$1"; }
info() { printf "  ${CYAN}→${NC} %s\n" "$1"; }
header() {
    echo ""
    printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    printf "${BOLD}  %s${NC}\n" "$1"
    printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

ask() {
    printf "  ${BOLD}%s${NC} " "$1" >/dev/tty
    read -r REPLY </dev/tty
    echo "$REPLY"
}

# ── Global state ───────────────────────────────────────────────
SWITCH_TYPE=""
SWITCH_DEV=""
DSA_PORTS=""
LAN_IP=""
LAN_SUBNET=""
LAN_IFACE=""
MODE=""
OPENWRT_VERSION=""
NFT_OK=0
HYBRID_AVAILABLE=0
declare_ports() { MAPPED_PORTS=""; }

# ══════════════════════════════════════════════════════════════
#  STEP 1 — PRE-FLIGHT CHECKS
# ══════════════════════════════════════════════════════════════
preflight_checks() {
    header "Router Traffic Monitor — Pre-flight Check"
    FAIL=0

    # ── OpenWrt version ──────────────────────────────────────
    echo ""
    echo "  Checking OpenWrt version..."
    if [ -f /etc/openwrt_release ]; then
        . /etc/openwrt_release
        OPENWRT_VERSION="$DISTRIB_RELEASE"
        MAJOR=$(echo "$DISTRIB_RELEASE" | cut -d. -f1)
        MINOR=$(echo "$DISTRIB_RELEASE" | cut -d. -f2 | cut -d- -f1)
        info "Detected  : OpenWrt $DISTRIB_RELEASE ($DISTRIB_ARCH)"
        info "Required  : $MIN_OPENWRT_MAJOR.$MIN_OPENWRT_MINOR or newer"
        if [ "$MAJOR" -gt "$MIN_OPENWRT_MAJOR" ] || \
           { [ "$MAJOR" -eq "$MIN_OPENWRT_MAJOR" ] && [ "$MINOR" -ge "$MIN_OPENWRT_MINOR" ]; }; then
            ok "Version OK"
        else
            fail "Version UNSUPPORTED"
            echo ""
            warn "OpenWrt $DISTRIB_RELEASE uses iptables, not nftables."
            warn "WiFi auto-detection requires nftables (OpenWrt 21.02+)."
            echo ""
            printf "  Options:\n"
            printf "    1) Exit and upgrade OpenWrt first (recommended)\n"
            printf "    2) Continue anyway (ethernet MIB only, no WiFi tracking)\n"
            printf "    3) Abort\n"
            echo ""
            CHOICE=$(ask "Your choice (1/2/3):")
            case "$CHOICE" in
                1) echo ""; info "Please upgrade OpenWrt then re-run installer."; exit 0 ;;
                2) warn "Continuing with limited functionality..."; NFT_OK=0 ;;
                3) exit 0 ;;
                *) exit 0 ;;
            esac
        fi
    else
        fail "Cannot detect OpenWrt version — /etc/openwrt_release missing"
        FAIL=1
    fi

    # ── Flash space ──────────────────────────────────────────
    echo ""
    echo "  Checking flash space..."
    FLASH_KB=$(df /overlay 2>/dev/null | awk 'NR==2{print int($4/1)}')
    info "Available : ${FLASH_KB} KB"
    info "Required  : ${MIN_FLASH_KB} KB minimum"
    if [ "${FLASH_KB:-0}" -ge "$MIN_FLASH_KB" ]; then
        ok "Flash OK"
    else
        fail "Insufficient flash space"
        warn "Only ${FLASH_KB}KB free, need ${MIN_FLASH_KB}KB minimum"
        FAIL=1
    fi

    # ── RAM ─────────────────────────────────────────────────
    echo ""
    echo "  Checking RAM..."
    RAM_MB=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
    info "Available : ${RAM_MB} MB"
    info "Required  : ${MIN_RAM_MB} MB minimum"
    if [ "${RAM_MB:-0}" -ge "$MIN_RAM_MB" ]; then
        ok "RAM OK"
    else
        fail "Insufficient RAM"
        FAIL=1
    fi

    # ── Architecture ─────────────────────────────────────────
    echo ""
    echo "  Checking architecture..."
    ARCH=$(uname -m)
    info "Detected  : $ARCH"
    ok "Architecture noted"

    echo ""
    printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

    if [ "$FAIL" = "1" ]; then
        fail "One or more checks failed. Fix issues and re-run installer."
        exit 1
    fi

    ok "All pre-flight checks passed."
    echo ""
    CHOICE=$(ask "Continue with installation? (y/n):")
    [ "$CHOICE" = "y" ] || [ "$CHOICE" = "Y" ] || exit 0
}

# ══════════════════════════════════════════════════════════════
#  STEP 2 — DETECT SWITCH TYPE
# ══════════════════════════════════════════════════════════════
detect_switch() {
    header "Detecting Switch Type"
    echo ""

    # 1. swconfig
    if command -v swconfig >/dev/null 2>&1; then
        SWITCH_DEV=$(swconfig list 2>/dev/null | awk 'NR==1{print $1}')
        if [ -n "$SWITCH_DEV" ]; then
            SWITCH_TYPE="swconfig"
            ok "Switch type : swconfig ($SWITCH_DEV)"
            HYBRID_AVAILABLE=1
            return
        fi
    fi

    # 2. DSA — find interfaces that are members of br-lan
    echo "  swconfig not found, checking for DSA..."
    DSA_PORTS=""
    for iface in /sys/class/net/*/; do
        name=$(basename "$iface")
        case "$name" in
            br-*|lo|wlan*|wifi*|ath*|radio*|mon*) continue ;;
        esac
        if [ -f "$iface/statistics/rx_bytes" ]; then
            # Check if part of br-lan bridge
            IN_BRIDGE=0
            brctl show br-lan 2>/dev/null | grep -q "^[[:space:]]*$name" && IN_BRIDGE=1
            bridge link 2>/dev/null | grep -q " $name " && IN_BRIDGE=1
            if [ "$IN_BRIDGE" = "1" ]; then
                DSA_PORTS="$DSA_PORTS $name"
            fi
        fi
    done
    DSA_PORTS=$(echo "$DSA_PORTS" | tr -s ' ' | sed 's/^ //')
    if [ -n "$DSA_PORTS" ]; then
        SWITCH_TYPE="dsa"
        ok "Switch type : DSA"
        info "LAN ports   : $DSA_PORTS"
        HYBRID_AVAILABLE=1
        return
    fi

    # 3. ethtool fallback
    echo "  DSA not detected, checking ethtool..."
    if command -v ethtool >/dev/null 2>&1; then
        for iface in /sys/class/net/*/; do
            name=$(basename "$iface")
            case "$name" in
                br-*|lo|wlan*|wifi*|ath*|radio*) continue ;;
            esac
            if ethtool -S "$name" 2>/dev/null | grep -qE "rx_bytes|RxGoodByte"; then
                SWITCH_TYPE="ethtool"
                ok "Switch type : ethtool ($name)"
                HYBRID_AVAILABLE=1
                return
            fi
        done
    fi

    # 4. None
    SWITCH_TYPE="none"
    warn "No managed switch detected"
    info "Only auto mode (WiFi + internet tracking) will be available"
    HYBRID_AVAILABLE=0
}

# ══════════════════════════════════════════════════════════════
#  STEP 3 — CHECK & INSTALL DEPENDENCIES
# ══════════════════════════════════════════════════════════════
check_deps() {
    header "Checking Dependencies"
    echo ""
    OPKG_UPDATED=0

    install_pkg() {
        PKG="$1"
        REASON="$2"
        printf "  Checking %-20s ... " "$PKG"
        if opkg list-installed 2>/dev/null | grep -q "^$PKG "; then
            printf "${GREEN}installed${NC}\n"
            return 0
        fi
        printf "${YELLOW}not found${NC}\n"
        info "Needed for: $REASON"
        CHOICE=$(ask "  Install $PKG now? (y/n):")
        if [ "$CHOICE" = "y" ] || [ "$CHOICE" = "Y" ]; then
            if [ "$OPKG_UPDATED" = "0" ]; then
                echo ""
                info "Running opkg update..."
                opkg update >/dev/null 2>&1
                OPKG_UPDATED=1
            fi
            echo ""
            info "Installing $PKG..."
            if opkg install "$PKG" >/dev/null 2>&1; then
                ok "$PKG installed successfully"
                return 0
            else
                fail "Failed to install $PKG"
                echo ""
                fail "Cannot continue without $PKG. Check internet connection and try again."
                exit 1
            fi
        else
            fail "Cannot continue without $PKG"
            exit 1
        fi
    }

    # Core dependencies
    install_pkg "nftables"    "WiFi device auto-detection"
    install_pkg "uhttpd"      "Serving CGI to ESP32"

    # awk is busybox built-in — just verify
    printf "  Checking %-20s ... " "awk"
    if command -v awk >/dev/null 2>&1; then
        printf "${GREEN}installed${NC}\n"
    else
        printf "${RED}missing${NC}\n"
        fail "awk not found — this is unusual for OpenWrt"
        install_pkg "gawk" "CGI data parsing"
    fi

    # swconfig only if needed
    if [ "$SWITCH_TYPE" = "swconfig" ]; then
        install_pkg "swconfig" "Ethernet port MIB counters"
    fi

    # bridge-utils for DSA detection
    if [ "$SWITCH_TYPE" = "dsa" ]; then
        printf "  Checking %-20s ... " "bridge"
        command -v bridge >/dev/null 2>&1 && \
            printf "${GREEN}installed${NC}\n" || \
            install_pkg "bridge-utils" "DSA interface detection"
    fi

    echo ""
    ok "All dependencies satisfied"
}

# ══════════════════════════════════════════════════════════════
#  STEP 4 — DETECT NETWORK
# ══════════════════════════════════════════════════════════════
detect_network() {
    header "Detecting Network"
    echo ""

    LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null)
    LAN_MASK=$(uci get network.lan.netmask 2>/dev/null)
    LAN_DEV=$(uci get network.lan.device 2>/dev/null)

    # Calculate subnet from IP and mask
    IFS=. read -r i1 i2 i3 i4 << EOF
$LAN_IP
EOF
    IFS=. read -r m1 m2 m3 m4 << EOF
$LAN_MASK
EOF
    LAN_SUBNET="$(( i1 & m1 )).$(( i2 & m2 )).$(( i3 & m3 )).$(( i4 & m4 ))"
    # Get prefix length
    PREFIX=0
    for m in $m1 $m2 $m3 $m4; do
        case $m in
            255) PREFIX=$((PREFIX+8)) ;;
            254) PREFIX=$((PREFIX+7)) ;;
            252) PREFIX=$((PREFIX+6)) ;;
            248) PREFIX=$((PREFIX+5)) ;;
            240) PREFIX=$((PREFIX+4)) ;;
            224) PREFIX=$((PREFIX+3)) ;;
            192) PREFIX=$((PREFIX+2)) ;;
            128) PREFIX=$((PREFIX+1)) ;;
        esac
    done
    LAN_CIDR="$LAN_SUBNET/$PREFIX"

    info "Router LAN IP : $LAN_IP"
    info "LAN Subnet    : $LAN_CIDR"
    info "LAN Device    : $LAN_DEV"
    echo ""
    ok "Network detected"
}

# ══════════════════════════════════════════════════════════════
#  STEP 5 — SELECT MODE
# ══════════════════════════════════════════════════════════════
select_mode() {
    header "Select Installation Mode"
    echo ""

    if [ "$HYBRID_AVAILABLE" = "0" ]; then
        warn "No managed switch detected on this router."
        info "Installing in Auto mode (WiFi + internet traffic only)"
        MODE="auto"
        return
    fi

    printf "  ${BOLD}1)${NC} Hybrid — Ethernet (MIB/sysfs) + WiFi (nft)\n"
    printf "     Full LAN-to-LAN traffic visibility for ethernet devices\n"
    printf "     Ethernet devices must be mapped manually during setup\n"
    echo ""
    printf "  ${BOLD}2)${NC} Auto — All devices via nft only\n"
    printf "     Any device auto-detected the moment it generates traffic\n"
    printf "     No LAN-to-LAN ethernet visibility\n"
    echo ""
    CHOICE=$(ask "Select mode (1/2):")
    case "$CHOICE" in
        1) MODE="hybrid" ;;
        2) MODE="auto" ;;
        *) MODE="auto"; warn "Invalid choice, defaulting to Auto mode" ;;
    esac
    echo ""
    ok "Mode selected: $MODE"
}

# ══════════════════════════════════════════════════════════════
#  STEP 6 — PORT/DEVICE MAPPING (hybrid only)
# ══════════════════════════════════════════════════════════════
map_ports() {
    [ "$MODE" = "auto" ] && return

    header "Ethernet Port Mapping"
    echo ""
    info "Connected devices (from DHCP leases):"
    echo ""
    printf "  %-18s %-20s %s\n" "IP Address" "Hostname" "MAC"
    printf "  %-18s %-20s %s\n" "──────────" "────────" "───"
    while IFS= read -r line; do
        MAC=$(echo "$line" | awk '{print $2}')
        IP=$(echo "$line"  | awk '{print $3}')
        HOST=$(echo "$line" | awk '{print $4}')
        printf "  %-18s %-20s %s\n" "$IP" "$HOST" "$MAC"
    done < /tmp/dhcp.leases
    echo ""

    MAPPED_PORTS=""

    case "$SWITCH_TYPE" in

        swconfig)
            info "Scanning switch ports for traffic..."
            echo ""
            printf "  %-8s %-20s %-20s %s\n" "Port" "RxGoodByte" "TxByte" "Status"
            printf "  %-8s %-20s %-20s %s\n" "────" "──────────" "──────" "──────"
            ACTIVE_PORTS=""
            i=0
            while [ $i -le 6 ]; do
                MIB=$(swconfig dev "$SWITCH_DEV" port $i get mib 2>/dev/null)
                RX=$(echo "$MIB" | awk '/RxGoodByte/{print $3+0}')
                TX=$(echo "$MIB" | awk '/TxByte/{print $3+0}')
                if [ -n "$RX" ]; then
                    if [ "$RX" -gt 0 ] || [ "$TX" -gt 0 ]; then
                        STATUS="active"
                        ACTIVE_PORTS="$ACTIVE_PORTS $i"
                    else
                        STATUS="idle"
                    fi
                    printf "  %-8s %-20s %-20s %s\n" "Port $i" "$RX" "$TX" "$STATUS"
                fi
                i=$((i+1))
            done
            echo ""
            info "Map active ports to device IPs."
            info "Press Enter to skip a port."
            echo ""
            for port in $ACTIVE_PORTS; do
                IP=$(ask "  Port $port → IP address (or Enter to skip):")
                if [ -n "$IP" ]; then
                    MAPPED_PORTS="$MAPPED_PORTS $port:$IP"
                    ok "Port $port mapped to $IP"
                fi
            done
            ;;

        dsa|ethtool)
            info "Scanning LAN interfaces for traffic..."
            echo ""
            printf "  %-12s %-20s %-20s %s\n" "Interface" "RX bytes" "TX bytes" "Status"
            printf "  %-12s %-20s %-20s %s\n" "─────────" "────────" "────────" "──────"
            ACTIVE_IFACES=""
            for iface in $DSA_PORTS; do
                RX=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
                TX=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
                if [ "$RX" -gt 0 ] || [ "$TX" -gt 0 ]; then
                    STATUS="active"
                    ACTIVE_IFACES="$ACTIVE_IFACES $iface"
                else
                    STATUS="idle"
                fi
                printf "  %-12s %-20s %-20s %s\n" "$iface" "$RX" "$TX" "$STATUS"
            done
            echo ""
            info "Map active interfaces to device IPs."
            info "Press Enter to skip an interface."
            echo ""
            for iface in $ACTIVE_IFACES; do
                IP=$(ask "  $iface → IP address (or Enter to skip):")
                if [ -n "$IP" ]; then
                    MAPPED_PORTS="$MAPPED_PORTS $iface:$IP"
                    ok "$iface mapped to $IP"
                fi
            done
            ;;
    esac

    if [ -z "$MAPPED_PORTS" ]; then
        warn "No ports mapped — switching to Auto mode"
        MODE="auto"
    fi
}

# ══════════════════════════════════════════════════════════════
#  STEP 7 — GENERATE & INSTALL FILES
# ══════════════════════════════════════════════════════════════

# ── Generate nft-acct.nft ─────────────────────────────────────
install_nft() {
    cat > "$NFT_PATH" << EOF
table ip acct {
    set rx_set {
        type ipv4_addr
        size 1024
        flags dynamic
    }
    set tx_set {
        type ipv4_addr
        size 1024
        flags dynamic
    }
    chain rx {
        type filter hook forward priority filter + 10; policy accept;
        ip daddr $LAN_CIDR add @rx_set { ip daddr counter }
    }
    chain tx {
        type filter hook forward priority filter + 11; policy accept;
        ip saddr $LAN_CIDR add @tx_set { ip saddr counter }
    }
}
EOF
    ok "Installed: $NFT_PATH"
}

# ── Generate hotplug script ───────────────────────────────────
install_hotplug() {
    cat > "$HOTPLUG_PATH" << 'EOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
[ "$INTERFACE" = "lan" ] || exit 0
sleep 3
nft list table ip acct >/dev/null 2>&1 && nft delete table ip acct
nft -f /etc/nft-acct.nft
logger -t acct "nft acct table loaded"
EOF
    chmod +x "$HOTPLUG_PATH"
    ok "Installed: $HOTPLUG_PATH"
}

# ── Generate auto CGI ─────────────────────────────────────────
install_cgi_auto() {
    cat > "$CGI_PATH" << 'CGEOF'
#!/bin/sh
echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo ""

SNAP1=$(mktemp)
SNAP2=$(mktemp)
TOTAL_DEVICES=$(wc -l < /tmp/dhcp.leases)

nft list table ip acct > "$SNAP1" &
wait

T1=$(cut -d' ' -f1 /proc/uptime | tr -d '.')
sleep 1
nft list table ip acct > "$SNAP2" &
wait
T2=$(cut -d' ' -f1 /proc/uptime | tr -d '.')

ELAPSED=$(( T2 - T1 ))
[ "$ELAPSED" -lt 90 ] && ELAPSED=90

awk -v elapsed="$ELAPSED" -v total="$TOTAL_DEVICES" '
BEGIN {
    in_rx=0; in_tx=0; cur_ip=""
    while ((getline line < ARGV[1]) > 0) {
        if (index(line,"rx_set")) { in_rx=1; in_tx=0 }
        if (index(line,"tx_set")) { in_tx=1; in_rx=0 }
        if (index(line,"chain"))  { in_rx=0; in_tx=0 }
        n=split(line,a," ")
        for(i=1;i<=n;i++) {
            if(a[i]~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) cur_ip=a[i]
            if(a[i]=="bytes" && cur_ip!="") {
                if(in_rx) rx1[cur_ip]=a[i+1]+0
                if(in_tx) tx1[cur_ip]=a[i+1]+0
                cur_ip=""
            }
        }
    }
    close(ARGV[1])
    in_rx=0; in_tx=0; cur_ip=""
    while ((getline line < ARGV[2]) > 0) {
        if (index(line,"rx_set")) { in_rx=1; in_tx=0 }
        if (index(line,"tx_set")) { in_tx=1; in_rx=0 }
        if (index(line,"chain"))  { in_rx=0; in_tx=0 }
        n=split(line,a," ")
        for(i=1;i<=n;i++) {
            if(a[i]~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) cur_ip=a[i]
            if(a[i]=="bytes" && cur_ip!="") {
                if(in_rx) { rx2[cur_ip]=a[i+1]+0; ips[cur_ip]=1 }
                if(in_tx)   tx2[cur_ip]=a[i+1]+0
                cur_ip=""
            }
        }
    }
    close(ARGV[2])
    printf "{\"total\":%d,\"devices\":[", total+0
    first=1
    for(ip in ips) {
        rx=(rx2[ip]-rx1[ip])*100/elapsed
        tx=(tx2[ip]-tx1[ip])*100/elapsed
        if(rx<0) rx=0
        if(tx<0) tx=0
        if(!first) printf ","
        printf "{\"ip\":\"%s\",\"rxRate\":%d,\"txRate\":%d}",ip,rx,tx
        first=0
    }
    printf "]}\n"
}
' "$SNAP1" "$SNAP2"

rm -f "$SNAP1" "$SNAP2"
CGEOF
    chmod +x "$CGI_PATH"
    ok "Installed: $CGI_PATH (auto mode)"
}

# ── Generate hybrid CGI (swconfig) ───────────────────────────
install_cgi_hybrid_swconfig() {
    # Build MIB snapshot blocks dynamically
    SNAP1_CMDS=""
    SNAP2_CMDS=""
    READ1_CMDS=""
    READ2_CMDS=""
    RATE_CMDS=""
    JSON_FIRST=""
    JSON_REST=""
    SKIP_IPS=""
    IDX=0

    for entry in $MAPPED_PORTS; do
        PORT=$(echo "$entry" | cut -d: -f1)
        IP=$(echo "$entry"   | cut -d: -f2)
        VAR="P${IDX}"

        SNAP1_CMDS="${SNAP1_CMDS}swconfig dev $SWITCH_DEV port $PORT get mib > \"\$T/${VAR}s1\" &\n"
        SNAP2_CMDS="${SNAP2_CMDS}swconfig dev $SWITCH_DEV port $PORT get mib > \"\$T/${VAR}s2\" &\n"
        READ1_CMDS="${READ1_CMDS}${VAR}_PRXI=\$(awk '/RxGoodByte/{print \$3+0}' \"\$T/${VAR}s1\")\n"
        READ1_CMDS="${READ1_CMDS}${VAR}_PTXI=\$(awk '/TxByte/{print \$3+0}'     \"\$T/${VAR}s1\")\n"
        READ2_CMDS="${READ2_CMDS}${VAR}_PRXF=\$(awk '/RxGoodByte/{print \$3+0}' \"\$T/${VAR}s2\")\n"
        READ2_CMDS="${READ2_CMDS}${VAR}_PTXF=\$(awk '/TxByte/{print \$3+0}'     \"\$T/${VAR}s2\")\n"
        RATE_CMDS="${RATE_CMDS}${VAR}_RX=\$(( (\$\{${VAR}_PTXF\} - \$\{${VAR}_PTXI\}) * 100 / ELAPSED ))\n"
        RATE_CMDS="${RATE_CMDS}${VAR}_TX=\$(( (\$\{${VAR}_PRXF\} - \$\{${VAR}_PRXI\}) * 100 / ELAPSED ))\n"
        RATE_CMDS="${RATE_CMDS}[ \"\$\{${VAR}_RX\}\" -lt 0 ] && ${VAR}_RX=0\n"
        RATE_CMDS="${RATE_CMDS}[ \"\$\{${VAR}_TX\}\" -lt 0 ] && ${VAR}_TX=0\n"

        if [ -z "$JSON_FIRST" ]; then
            JSON_FIRST="printf '{\"ip\":\"$IP\",\"rxRate\":%d,\"txRate\":%d}' \"\$${VAR}_RX\" \"\$${VAR}_TX\""
        else
            JSON_REST="${JSON_REST}printf ',{\"ip\":\"$IP\",\"rxRate\":%d,\"txRate\":%d}' \"\$${VAR}_RX\" \"\$${VAR}_TX\"\n"
        fi

        if [ -z "$SKIP_IPS" ]; then
            SKIP_IPS="ip == \"$IP\""
        else
            SKIP_IPS="$SKIP_IPS || ip == \"$IP\""
        fi
        IDX=$((IDX+1))
    done

    cat > "$CGI_PATH" << CGEOF
#!/bin/sh
echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo ""

T=\$(mktemp -d)
SNAP1=\$(mktemp)
SNAP2=\$(mktemp)

# Snapshot 1
$(printf "$SNAP1_CMDS")swconfig dev $SWITCH_DEV show > /dev/null &
nft list table ip acct > "\$SNAP1" &
wait

$(printf "$READ1_CMDS")
T1=\$(cut -d' ' -f1 /proc/uptime | tr -d '.')
sleep 1

# Snapshot 2
$(printf "$SNAP2_CMDS")nft list table ip acct > "\$SNAP2" &
wait

T2=\$(cut -d' ' -f1 /proc/uptime | tr -d '.')
$(printf "$READ2_CMDS")
rm -rf "\$T"

ELAPSED=\$(( T2 - T1 ))
[ "\$ELAPSED" -lt 90 ] && ELAPSED=90

$(printf "$RATE_CMDS")

# WiFi via nft
WIFI_JSON=\$(awk -v elapsed="\$ELAPSED" '
BEGIN {
    in_rx=0; in_tx=0; cur_ip=""
    while ((getline line < ARGV[1]) > 0) {
        if (index(line,"rx_set")) { in_rx=1; in_tx=0 }
        if (index(line,"tx_set")) { in_tx=1; in_rx=0 }
        if (index(line,"chain"))  { in_rx=0; in_tx=0 }
        n=split(line,a," ")
        for(i=1;i<=n;i++) {
            if(a[i]~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) cur_ip=a[i]
            if(a[i]=="bytes" && cur_ip!="") {
                if(in_rx) rx1[cur_ip]=a[i+1]+0
                if(in_tx) tx1[cur_ip]=a[i+1]+0
                cur_ip=""
            }
        }
    }
    close(ARGV[1])
    in_rx=0; in_tx=0; cur_ip=""
    while ((getline line < ARGV[2]) > 0) {
        if (index(line,"rx_set")) { in_rx=1; in_tx=0 }
        if (index(line,"tx_set")) { in_tx=1; in_rx=0 }
        if (index(line,"chain"))  { in_rx=0; in_tx=0 }
        n=split(line,a," ")
        for(i=1;i<=n;i++) {
            if(a[i]~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) cur_ip=a[i]
            if(a[i]=="bytes" && cur_ip!="") {
                if(in_rx) { rx2[cur_ip]=a[i+1]+0; ips[cur_ip]=1 }
                if(in_tx)   tx2[cur_ip]=a[i+1]+0
                cur_ip=""
            }
        }
    }
    close(ARGV[2])
    for(ip in ips) {
        if($SKIP_IPS) continue
        rx=(rx2[ip]-rx1[ip])*100/elapsed
        tx=(tx2[ip]-tx1[ip])*100/elapsed
        if(rx<0) rx=0
        if(tx<0) tx=0
        printf ",{\"ip\":\"%s\",\"rxRate\":%d,\"txRate\":%d}",ip,rx,tx
    }
}
' "\$SNAP1" "\$SNAP2")

rm -f "\$SNAP1" "\$SNAP2"

TOTAL_DEVICES=\$(wc -l < /tmp/dhcp.leases)
printf '{"total":%d,"devices":[' "\$TOTAL_DEVICES"
$JSON_FIRST
$(printf "$JSON_REST")printf '%s' "\$WIFI_JSON"
printf ']}\n'
CGEOF
    chmod +x "$CGI_PATH"
    ok "Installed: $CGI_PATH (hybrid/swconfig mode)"
}

# ── Generate hybrid CGI (DSA/sysfs) ──────────────────────────
install_cgi_hybrid_dsa() {
    SNAP1_CMDS=""
    SNAP2_CMDS=""
    RATE_CMDS=""
    JSON_FIRST=""
    JSON_REST=""
    SKIP_IPS=""
    IDX=0

    for entry in $MAPPED_PORTS; do
        IFACE=$(echo "$entry" | cut -d: -f1)
        IP=$(echo "$entry"    | cut -d: -f2)
        VAR="P${IDX}"

        SNAP1_CMDS="${SNAP1_CMDS}${VAR}_RXI=\$(cat /sys/class/net/$IFACE/statistics/rx_bytes)\n"
        SNAP1_CMDS="${SNAP1_CMDS}${VAR}_TXI=\$(cat /sys/class/net/$IFACE/statistics/tx_bytes)\n"
        SNAP2_CMDS="${SNAP2_CMDS}${VAR}_RXF=\$(cat /sys/class/net/$IFACE/statistics/rx_bytes)\n"
        SNAP2_CMDS="${SNAP2_CMDS}${VAR}_TXF=\$(cat /sys/class/net/$IFACE/statistics/tx_bytes)\n"
        RATE_CMDS="${RATE_CMDS}${VAR}_RX=\$(( (\$\{${VAR}_RXF\} - \$\{${VAR}_RXI\}) * 100 / ELAPSED ))\n"
        RATE_CMDS="${RATE_CMDS}${VAR}_TX=\$(( (\$\{${VAR}_TXF\} - \$\{${VAR}_TXI\}) * 100 / ELAPSED ))\n"
        RATE_CMDS="${RATE_CMDS}[ \"\$\{${VAR}_RX\}\" -lt 0 ] && ${VAR}_RX=0\n"
        RATE_CMDS="${RATE_CMDS}[ \"\$\{${VAR}_TX\}\" -lt 0 ] && ${VAR}_TX=0\n"

        if [ -z "$JSON_FIRST" ]; then
            JSON_FIRST="printf '{\"ip\":\"$IP\",\"rxRate\":%d,\"txRate\":%d}' \"\$${VAR}_RX\" \"\$${VAR}_TX\""
        else
            JSON_REST="${JSON_REST}printf ',{\"ip\":\"$IP\",\"rxRate\":%d,\"txRate\":%d}' \"\$${VAR}_RX\" \"\$${VAR}_TX\"\n"
        fi

        if [ -z "$SKIP_IPS" ]; then
            SKIP_IPS="ip == \"$IP\""
        else
            SKIP_IPS="$SKIP_IPS || ip == \"$IP\""
        fi
        IDX=$((IDX+1))
    done

    cat > "$CGI_PATH" << CGEOF
#!/bin/sh
echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo ""

SNAP1=\$(mktemp)
SNAP2=\$(mktemp)

# Snapshot 1
$(printf "$SNAP1_CMDS")nft list table ip acct > "\$SNAP1" &
wait

T1=\$(cut -d' ' -f1 /proc/uptime | tr -d '.')
sleep 1

# Snapshot 2
$(printf "$SNAP2_CMDS")nft list table ip acct > "\$SNAP2" &
wait

T2=\$(cut -d' ' -f1 /proc/uptime | tr -d '.')

ELAPSED=\$(( T2 - T1 ))
[ "\$ELAPSED" -lt 90 ] && ELAPSED=90

$(printf "$RATE_CMDS")

# WiFi via nft
WIFI_JSON=\$(awk -v elapsed="\$ELAPSED" '
BEGIN {
    in_rx=0; in_tx=0; cur_ip=""
    while ((getline line < ARGV[1]) > 0) {
        if (index(line,"rx_set")) { in_rx=1; in_tx=0 }
        if (index(line,"tx_set")) { in_tx=1; in_rx=0 }
        if (index(line,"chain"))  { in_rx=0; in_tx=0 }
        n=split(line,a," ")
        for(i=1;i<=n;i++) {
            if(a[i]~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) cur_ip=a[i]
            if(a[i]=="bytes" && cur_ip!="") {
                if(in_rx) rx1[cur_ip]=a[i+1]+0
                if(in_tx) tx1[cur_ip]=a[i+1]+0
                cur_ip=""
            }
        }
    }
    close(ARGV[1])
    in_rx=0; in_tx=0; cur_ip=""
    while ((getline line < ARGV[2]) > 0) {
        if (index(line,"rx_set")) { in_rx=1; in_tx=0 }
        if (index(line,"tx_set")) { in_tx=1; in_rx=0 }
        if (index(line,"chain"))  { in_rx=0; in_tx=0 }
        n=split(line,a," ")
        for(i=1;i<=n;i++) {
            if(a[i]~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) cur_ip=a[i]
            if(a[i]=="bytes" && cur_ip!="") {
                if(in_rx) { rx2[cur_ip]=a[i+1]+0; ips[cur_ip]=1 }
                if(in_tx)   tx2[cur_ip]=a[i+1]+0
                cur_ip=""
            }
        }
    }
    close(ARGV[2])
    for(ip in ips) {
        if($SKIP_IPS) continue
        rx=(rx2[ip]-rx1[ip])*100/elapsed
        tx=(tx2[ip]-tx1[ip])*100/elapsed
        if(rx<0) rx=0
        if(tx<0) tx=0
        printf ",{\"ip\":\"%s\",\"rxRate\":%d,\"txRate\":%d}",ip,rx,tx
    }
}
' "\$SNAP1" "\$SNAP2")

rm -f "\$SNAP1" "\$SNAP2"

TOTAL_DEVICES=\$(wc -l < /tmp/dhcp.leases)
printf '{"total":%d,"devices":[' "\$TOTAL_DEVICES"
$JSON_FIRST
$(printf "$JSON_REST")printf '%s' "\$WIFI_JSON"
printf ']}\n'
CGEOF
    chmod +x "$CGI_PATH"
    ok "Installed: $CGI_PATH (hybrid/DSA mode)"
}

install_files() {
    header "Installing Files"
    echo ""

    install_nft
    install_hotplug

    case "$MODE" in
        auto) install_cgi_auto ;;
        hybrid)
            case "$SWITCH_TYPE" in
                swconfig)        install_cgi_hybrid_swconfig ;;
                dsa|ethtool)     install_cgi_hybrid_dsa ;;
            esac
            ;;
    esac

    echo ""
    info "Loading nft table..."
    nft list table ip acct >/dev/null 2>&1 && nft delete table ip acct
    if nft -f "$NFT_PATH"; then
        ok "nft table loaded"
    else
        fail "nft table failed to load"
        exit 1
    fi

    echo ""
    info "Verifying firewall4 masquerade intact..."
    if nft list ruleset | grep -q "masquerade"; then
        ok "Masquerade OK — internet will work after reboot"
    else
        warn "Masquerade not found — check your firewall"
    fi
}

# ══════════════════════════════════════════════════════════════
#  STEP 8 — TEST CGI
# ══════════════════════════════════════════════════════════════
test_cgi() {
    header "Testing CGI"
    echo ""
    info "Running CGI (takes ~1 second)..."
    echo ""
    OUTPUT=$(sh "$CGI_PATH" 2>&1)
    JSON=$(echo "$OUTPUT" | grep '^{')
    if echo "$JSON" | grep -q '"ip"'; then
        ok "CGI output OK"
        echo ""
        echo "  $JSON" | tr ',' '\n' | sed 's/\[//' | sed 's/\]//' | while IFS= read -r dev; do
            [ -z "$dev" ] && continue
            IP=$(echo "$dev"  | grep -o '"ip":"[^"]*"'      | cut -d: -f2 | tr -d '"')
            RX=$(echo "$dev"  | grep -o '"rxRate":[0-9]*'   | cut -d: -f2)
            TX=$(echo "$dev"  | grep -o '"txRate":[0-9]*'   | cut -d: -f2)
            printf "  %-18s  ↓ %-12s  ↑ %s\n" "$IP" "${RX} B/s" "${TX} B/s"
        done
    else
        fail "CGI output unexpected:"
        echo "$OUTPUT"
        warn "Check the CGI manually: sh $CGI_PATH"
    fi
}

# ══════════════════════════════════════════════════════════════
#  STEP 9 — PRINT ESP32 CONFIG
# ══════════════════════════════════════════════════════════════
print_esp32_config() {
    header "ESP32 Setup"
    echo ""
    printf "${BOLD}  Flash the ESP32 sketch from:${NC}\n"
    printf "  https://github.com/Onimous-git/router-traffic-monitor/tree/main/esp32\n"
    echo ""
    printf "${BOLD}  Set this endpoint in the ESP32 web UI:${NC}\n"
    printf "  ${CYAN}http://$LAN_IP/cgi-bin/traffic.cgi${NC}\n"
    echo ""
    printf "${BOLD}  After flashing:${NC}\n"
    printf "  1) Connect ESP32 to your router WiFi\n"
    printf "  2) Find ESP32 IP from router DHCP leases: cat /tmp/dhcp.leases\n"
    printf "  3) Open http://<ESP32-IP> in browser\n"
    printf "  4) Set endpoint URL and device names\n"
    echo ""
    printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    printf "${GREEN}${BOLD}  Installation complete!${NC}\n"
    printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    echo ""
}

# ══════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════
main() {
    clear
    echo ""
    printf "${BOLD}${CYAN}"
    echo "  ╔═══════════════════════════════════════════════════╗"
    echo "  ║       Router Traffic Monitor — Installer          ║"
    echo "  ║   github.com/Onimous-git/router-traffic-monitor   ║"
    echo "  ╚═══════════════════════════════════════════════════╝"
    printf "${NC}"
    echo ""

    preflight_checks
    detect_switch
    check_deps
    detect_network
    select_mode
    map_ports
    install_files
    test_cgi
    print_esp32_config
}

main
