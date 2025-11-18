#!/bin/bash

# =======================
# Ultimate Server Protector v2.0
# Fully Fixed & Optimized Edition
# For Ubuntu (20.04 / 22.04)
# =======================

# --- Color Codes ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Global Variables & Directories ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COUNTRY_DIR="$SCRIPT_DIR/country"
LOG_FILE="/var/log/server_protector.log"

# --- Pre-flight Checks ---
# 1. Check for Root Access
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}ERROR: This script must be run as root.${NC}"
   exit 1
fi

# 2. Initialize Log File and Directory
mkdir -p "$COUNTRY_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE" # Secure log file

# --- Utility Functions ---
function press_enter() {
    echo -ne "\n${YELLOW}Press Enter to continue...${NC}" && read
}

function logo() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    Ultimate Server Protector v2.0             ║"
    echo "║                  Fully Fixed & Optimized Edition             ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

function log_action() {
    local action=$1
    local details=$2
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ACTION: $action - DETAILS: $details" >> "$LOG_FILE"
}

function backup_config() {
    local config_file=$1
    if [[ -f $config_file ]]; then
        local backup_file="${config_file}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$config_file" "$backup_file"
        log_action "BACKUP" "Created backup of $config_file at $backup_file"
        echo -e "${BLUE}[*] Backup of $config_file created.${NC}"
    fi
}

function check_ufw() {
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        echo -e "${RED}!!! WARNING: UFW Firewall is active !!!${NC}"
        echo -e "${YELLOW}This script manipulates iptables directly, which can conflict with UFW rules.${NC}"
        echo -e "${YELLOW}It's recommended to disable UFW or manage rules through UFW only.${NC}"
        read -p "Are you sure you want to continue? (y/N): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo -e "${GREEN}Operation cancelled by user.${NC}"
            return 1 # Exit status 1 means not confirmed
        fi
    fi
    return 0 # Exit status 0 means confirmed
}

# --- Core Functions ---
function pre_requisites() {
    echo -e "${YELLOW}[+] Updating packages and installing required tools...${NC}"
    log_action "PRE-REQUISITES" "Starting package update and installation."
    apt update -y
    apt install -y ipset iptables curl net-tools # Added net-tools for ifconfig
    log_action "PRE-REQUISITES" "Required tools (ipset, iptables, curl) installed/updated."
    echo -e "${GREEN}[+] Pre-requisites installed successfully.${NC}"
    press_enter
}

function install_crowdsec() {
    echo -e "${CYAN}[*] Installing and configuring CrowdSec Anti-DDoS...${NC}"
    log_action "CROWDSEC" "Starting installation and configuration."

    # Install CrowdSec
    curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
    apt-get install -y crowdsec

    # Install Collections and Bouncers
    log_action "CROWDSEC" "Installing collections: linux, sshd, http-cve."
    cscli collections install crowdsecurity/linux crowdsecurity/sshd crowdsecurity/http-cve
    log_action "CROWDSEC" "Installing bouncer: crowdsec-firewall-bouncer-iptables."
    cscli bouncers install crowdsec-firewall-bouncer-iptables

    # --- Advanced Configuration ---
    local config_path="/etc/crowdsec/config.yaml"
    backup_config "$config_path"

    # Update configuration for persistence and specific process monitoring
    # Using sed for robust in-place editing
    sed -i 's/mode: .*/mode: live/' "$config_path"
    sed -i 's/#log_level: info/log_level: info/' "$config_path"
    
    # Add specific process acquisition if not present
    if ! grep -q "acquisition:" "$config_path"; then
        cat << EOF >> "$config_path"

acquisition:
  - path: /var/log/auth.log
    labels:
      type: syslog
  - path: /var/log/nginx/access.log
    labels:
      type: nginx
  - path: /var/log/apache2/access.log
    labels:
      type: apache
EOF
    fi
    
    log_action "CROWDSEC" "Configuration file $config_path updated."

    # Enable and restart services
    systemctl enable crowdsec
    systemctl enable crowdsec-firewall-bouncer
    systemctl restart crowdsec
    systemctl restart crowdsec-firewall-bouncer

    echo -e "${GREEN}[+] CrowdSec Anti-DDoS installed and configured successfully.${NC}"
    log_action "CROWDSEC" "Installation and configuration completed successfully."
    press_enter
}

function uninstall_crowdsec() {
    echo -e "${YELLOW}[*] Removing CrowdSec Anti-DDoS...${NC}"
    log_action "CROWDSEC" "Starting uninstallation."
    systemctl stop crowdsec crowdsec-firewall-bouncer
    systemctl disable crowdsec crowdsec-firewall-bouncer
    apt-get purge -y crowdsec crowdsec-firewall-bouncer-iptables
    rm -rf /etc/crowdsec /var/lib/crowdsec /var/log/crowdsec*
    echo -e "${GREEN}[+] CrowdSec completely removed.${NC}"
    log_action "CROWDSEC" "Uninstallation completed."
    press_enter
}

function download_country_file() {
    local cc=$1
    cc="${cc,,}" # lowercase
    local zone_file="$COUNTRY_DIR/$cc.zone"
    local url="https://www.ipdeny.com/ipblocks/data/countries/$cc.zone"

    echo -e "${YELLOW}[*] Attempting to download $cc.zone...${NC}"
    log_action "COUNTRY_IPS" "Attempting download of $cc.zone from $url."

    if curl -f -s -o "$zone_file" "$url"; then
        if [[ -s "$zone_file" ]]; then
            echo -e "${GREEN}[+] $cc.zone downloaded successfully.${NC}"
            log_action "COUNTRY_IPS" "Successfully downloaded $cc.zone."
            return 0
        else
            echo -e "${RED}[!] ERROR: Downloaded file $zone_file is empty.${NC}"
            log_action "COUNTRY_IPS" "ERROR: Downloaded file $zone_file is empty."
            rm -f "$zone_file"
            return 1
        fi
    else
        echo -e "${RED}[!] ERROR: Failed to download $cc.zone. Check country code or internet connection.${NC}"
        log_action "COUNTRY_IPS" "ERROR: Failed to download $cc.zone."
        return 1
    fi
}

function _apply_country_ban() {
    local cc=$1
    local direction=$2 # "src" for INPUT, "dst" for OUTPUT
    local set_name="${cc}_${direction}"
    local iptables_chain=$([ "$direction" == "src" ] && echo "INPUT" || echo "OUTPUT")
    local zone_file="$COUNTRY_DIR/$cc.zone"

    if [[ ! -f "$zone_file" ]]; then
        download_country_file "$cc"
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}[!] Cannot proceed without $cc.zone file.${NC}"
            return 1
        fi
    fi

    check_ufw || return 1 # Exit if UFW is active and user cancels

    echo -e "${YELLOW}[*] Applying ban for country '$cc' on $iptables_chain...${NC}"
    log_action "COUNTRY_BAN" "Applying ban for country '$cc' on chain $iptables_chain."

    ipset destroy "$set_name" 2>/dev/null
    ipset create "$set_name" hash:net

    while read -r ip; do
        ipset add -exist "$set_name" "$ip"
    done < "$zone_file"

    if ! iptables -C "$iptables_chain" -m set --match-set "$set_name" "$direction" -j DROP &>/dev/null; then
        iptables -I "$iptables_chain" -m set --match-set "$set_name" "$direction" -j DROP
        echo -e "${GREEN}[+] Traffic for country '$cc' on $iptables_chain banned successfully.${NC}"
        log_action "COUNTRY_BAN" "Successfully banned country '$cc' on $iptables_chain."
    else
        echo -e "${BLUE}[*] Rule for country '$cc' on $iptables_chain already exists.${NC}"
    fi
}

function ban_country_request() {
    read -p "Enter 2-letter country code to block (e.g., ru, cn): " cc
    cc="${cc,,}"
    _apply_country_ban "$cc" "src"
    press_enter
}

function ban_country_connect() {
    read -p "Enter 2-letter country code to block outgoing (e.g., ru, cn): " cc
    cc="${cc,,}"
    _apply_country_ban "$cc" "dst"
    press_enter
}

function unban_country() {
    read -p "Enter 2-letter country code to unban (e.g., ru, cn): " cc
    cc="${cc,,}"
    echo -e "${YELLOW}[*] Removing all bans for country '$cc'...${NC}"
    log_action "COUNTRY_UNBAN" "Removing all bans for country '$cc'."
    
    # Remove incoming ban
    while iptables -C INPUT -m set --match-set "${cc}_src" src -j DROP &>/dev/null; do
        iptables -D INPUT -m set --match-set "${cc}_src" src -j DROP
    done
    ipset destroy "${cc}_src" 2>/dev/null

    # Remove outgoing ban
    while iptables -C OUTPUT -m set --match-set "${cc}_dst" dst -j DROP &>/dev/null; do
        iptables -D OUTPUT -m set --match-set "${cc}_dst" dst -j DROP
    done
    ipset destroy "${cc}_dst" 2>/dev/null
    
    echo -e "${GREEN}[+] Country '$cc' unbanned completely.${NC}"
    log_action "COUNTRY_UNBAN" "Successfully unbanned country '$cc'."
    press_enter
}

function optimize_network() {
    echo -e "${CYAN}[*] Optimizing network (BBR + FQ_CoDel + Persistent DNS)...${NC}"
    log_action "NETWORK_OPTIMIZE" "Starting network optimization."

    # --- BBR & FQ_CoDel ---
    backup_config "/etc/sysctl.conf"
    modprobe tcp_bbr
    if ! grep -q "tcp_bbr" /etc/modules-load.d/modules.conf 2>/dev/null; then
        echo "tcp_bbr" >> /etc/modules-load.d/modules.conf
    fi

    # Make sysctl settings persistent
    grep -q "net.ipv4.tcp_congestion_control" /etc/sysctl.conf && sed -i 's/net.ipv4.tcp_congestion_control.*/net.ipv4.tcp_congestion_control=bbr/' /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    grep -q "net.core.default_qdisc" /etc/sysctl.conf && sed -i 's/net.core.default_qdisc.*/net.core.default_qdisc=fq_codel/' /etc/sysctl.conf || echo "net.core.default_qdisc=fq_codel" >> /etc/sysctl.conf
    
    sysctl -p # Apply settings immediately
    log_action "NETWORK_OPTIMIZE" "Applied BBR and FQ_CoDel settings."

    # --- Persistent DNS ---
    echo -e "${YELLOW}[*] Choose DNS:${NC}"
    echo -e "${RED}1.${NC} ${CYAN}Google${NC}"
    echo -e "${RED}2.${NC} ${CYAN}Cloudflare${NC}"
    echo -e "${RED}3.${NC} ${CYAN}Quad9${NC}"
    echo -e "${RED}4.${NC} ${CYAN}403 Online (Anti Sanction)${NC}"
    read -p "Select DNS: " dns_choice

    case $dns_choice in
        1) dns_servers="nameserver 8.8.8.8\nnameserver 8.8.4.4";;
        2) dns_servers="nameserver 1.1.1.1\nnameserver 1.0.0.1";; # Corrected secondary
        3) dns_servers="nameserver 9.9.9.9\nnameserver 149.112.112.112";;
        4) dns_servers="nameserver 10.202.10.202\nnameserver 10.202.10.102";;
        *) echo -e "${RED}Invalid choice, setting Google DNS by default.${NC}"
           dns_servers="nameserver 8.8.8.8\nnameserver 8.8.4.4";;
    esac

    backup_config "/etc/resolv.conf"
    
    # Try to make DNS persistent via Netplan (Ubuntu 18.04+)
    if command -v netplan &> /dev/null && [[ -d /etc/netplan ]]; then
        local netplan_file=$(find /etc/netplan -maxdepth 1 -name '*.yaml' | head -n 1)
        if [[ -n "$netplan_file" ]]; then
            backup_config "$netplan_file"
            # This is a simplified approach. A real solution might need yaml parsing.
            cat << EOF > "$netplan_file"
network:
  version: 2
  ethernets:
    eth0: # Replace with your main interface name if different
      nameservers:
        addresses: [$(echo -e "$dns_servers" | grep nameserver | awk '{print $2}' | tr '\n' ', ' | sed 's/,$//')]
EOF
            netplan apply
            echo -e "${GREEN}[+] DNS settings applied via Netplan.${NC}"
            log_action "NETWORK_OPTIMIZE" "DNS settings applied via Netplan."
        else
             echo -e -n "$dns_servers" > /etc/resolv.conf
             echo -e "${GREEN}[+] DNS settings applied to /etc/resolv.conf.${NC}"
             log_action "NETWORK_OPTIMIZE" "DNS settings applied to /etc/resolv.conf."
        fi
    else
        echo -e -n "$dns_servers" > /etc/resolv.conf
        echo -e "${GREEN}[+] DNS settings applied to /etc/resolv.conf.${NC}"
        log_action "NETWORK_OPTIMIZE" "DNS settings applied to /etc/resolv.conf."
    fi

    echo -e "${GREEN}[+] Network optimized successfully.${NC}"
    press_enter
}

function set_mtu() {
    read -p "Enter MTU value (e.g., 1400, range 576-9000): " mtu
    if ! [[ "$mtu" =~ ^[0-9]+$ ]] || [[ "$mtu" -lt 576 ]] || [[ "$mtu" -gt 9000 ]]; then
        echo -e "${RED}[!] Invalid MTU value. Please enter a number between 576 and 9000.${NC}"
        press_enter
        return
    fi
    
    echo -e "${YELLOW}[*] Setting MTU to $mtu for all active interfaces...${NC}"
    log_action "SET_MTU" "Setting MTU to $mtu."
    ip link | awk -F": " '/^[0-9]+: / && !/lo/ {print $2}' | while read iface; do
        ip link set dev "$iface" mtu "$mtu"
        echo -e "${BLUE}[*] MTU for $iface set to $mtu.${NC}"
    done
    echo -e "${GREEN}[+] MTU set to $mtu successfully.${NC}"
    log_action "SET_MTU" "MTU set to $mtu successfully."
    press_enter
}

function ban_ip() {
    read -p "Enter IP to ban (e.g., 192.168.1.100): " ip
    # Simple IP validation
    if [[ ! $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo -e "${RED}[!] Invalid IP address format.${NC}"
        press_enter
        return
    fi

    check_ufw || return 1
    log_action "IP_BAN" "Banning IP: $ip."
    iptables -I INPUT -s "$ip" -j DROP
    iptables -I OUTPUT -d "$ip" -j DROP
    echo -e "${GREEN}[+] IP $ip fully blocked.${NC}"
    press_enter
}

function unban_ip() {
    read -p "Enter IP to unban (e.g., 192.168.1.100): " ip
    log_action "IP_UNBAN" "Unbanning IP: $ip."
    iptables -D INPUT -s "$ip" -j DROP 2>/dev/null && echo -e "${GREEN}[+] Removed incoming ban for $ip.${NC}" || echo -e "${YELLOW}[!] Incoming ban for $ip not found.${NC}"
    iptables -D OUTPUT -d "$ip" -j DROP 2>/dev/null && echo -e "${GREEN}[+] Removed outgoing ban for $ip.${NC}" || echo -e "${YELLOW}[!] Outgoing ban for $ip not found.${NC}"
    log_action "IP_UNBAN" "Unbanned IP: $ip."
    press_enter
}

function swap_maker() {
    echo -e "${YELLOW}[*] Select swap size:${NC}"
    echo -e "${RED}1. 512MB\n2. 1GB\n3. 2GB\n4. 4GB\n5. Manual\n${RED}6. No swap / Remove existing swap${NC}"
    read -p "Choice: " ch
    case $ch in
        1) swap_size="512";;
        2) swap_size="1024";;
        3) swap_size="2048";;
        4) swap_size="4096";;
        5) read -p "Enter size in MB (e.g., 300 for 300MB): " swap_size;;
        6) 
            echo -e "${YELLOW}[*] Removing existing swap...${NC}"
            log_action "SWAP" "Removing swap."
            swapoff -a
            sed -i '/\/swapfile/d' /etc/fstab
            rm -f /swapfile
            echo -e "${GREEN}[+] Swap removed successfully.${NC}"
            press_enter
            return
            ;;
        *) echo -e "${RED}[!] Invalid choice!${NC}"; press_enter; return;;
    esac

    if ! [[ "$swap_size" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}[!] Invalid size. Please enter a number.${NC}"
        press_enter
        return
    fi

    echo -e "${YELLOW}[*] Creating ${swap_size}MB swap file...${NC}"
    log_action "SWAP" "Creating ${swap_size}MB swap file."
    
    swapoff -a
    rm -f /swapfile
    dd if=/dev/zero of=/swapfile bs=1M count="$swap_size" status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    backup_config "/etc/fstab"
    if ! grep -q "/swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    backup_config "/etc/sysctl.conf"
    sysctl vm.swappiness=10
    grep -q "vm.swappiness" /etc/sysctl.conf && sed -i 's/vm.swappiness.*/vm.swappiness=10/' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf

    echo -e "${GREEN}[+] Swap of ${swap_size}MB configured successfully.${NC}"
    log_action "SWAP" "Swap of ${swap_size}MB configured successfully."
    press_enter
}

function block_porn() {
    echo -e "${CYAN}[*] Blocking Adult Content via DNS (AdGuard Family DNS)...${NC}"
    log_action "BLOCK_PORN" "Applying AdGuard Family DNS."
    backup_config "/etc/resolv.conf"
    echo -e "nameserver 94.140.14.15\nnameserver 94.140.15.16" > /etc/resolv.conf
    echo -e "${GREEN}[+] Adult content blocked using DNS filtering.${NC}"
    echo -e "${YELLOW}[!] Note: This setting is not persistent across reboots on all systems. Use 'Optimize Network' for a permanent solution.${NC}"
    log_action "BLOCK_PORN" "Adult content blocked."
    press_enter
}

# --- Main Script Execution ---
pre_requisites

while true; do
    logo
    echo -e "\n${YELLOW}Select an option:${NC}"
    echo -e "${GREEN}1.${NC} Install & Configure Anti-DDoS (CrowdSec)"
    echo -e "${GREEN}2.${NC} Ban Country (Incoming Traffic)"
    echo -e "${GREEN}3.${NC} Ban Country (Outgoing Traffic)"
    echo -e "${GREEN}4.${NC} Unban Country"
    echo -e "${GREEN}5.${NC} Optimize Server Network (BBR + DNS)"
    echo -e "${GREEN}6.${NC} Set MTU for All Interfaces"
    echo -e "${GREEN}7.${NC} Ban an IP Address"
    echo -e "${GREEN}8.${NC} Unban an IP Address"
    echo -e "${GREEN}9.${NC} Create/Remove Virtual RAM (Swap)"
    echo -e "${GREEN}10.${NC} Block Adult Content (Temporary DNS)"
    echo -e "${GREEN}11.${NC} Remove Anti-DDoS System (CrowdSec)"
    echo -e "${RED}0.${NC} Exit"
    read -p "Enter choice: " opt

    case $opt in
        1) install_crowdsec;;
        2) ban_country_request;;
        3) ban_country_connect;;
        4) unban_country;;
        5) optimize_network;;
        6) set_mtu;;
        7) ban_ip;;
        8) unban_ip;;
        9) swap_maker;;
        10) block_porn;;
        11) uninstall_crowdsec;;
        0) echo -e "${YELLOW}[*] Exiting... Bye!${NC}"; log_action "EXIT" "Script terminated by user."; exit 0;;
        *) echo -e "${RED}[!] Invalid option! Try again.${NC}"; press_enter;;
    esac
done
