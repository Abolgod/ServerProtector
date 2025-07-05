#!/bin/bash

# =======================
# Ultimate Server Protector v1.1
# For Ubuntu (compatible with 20.04 / 22.04)
# =======================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

COUNTRY_DIR="$(pwd)/country"

function press_enter() {
    echo -ne "\nPress Enter to continue..." && read
}

function logo() {
    echo -e "${CYAN}╔════════════════════════════╗"
    echo -e "║  Ultimate Server Protector ║"
    echo -e "╚════════════════════════════╝${NC}"
}

function download_country_file() {
    local cc=$1
    cc="${cc,,}"  # lowercase
    mkdir -p "$COUNTRY_DIR"
    url="https://www.ipdeny.com/ipblocks/data/countries/$cc.zone"
    echo -e "${YELLOW}Downloading $cc.zone...${NC}"
    curl -f -s -o "$COUNTRY_DIR/$cc.zone" "$url"
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to download $cc.zone${NC}"
        return 1
    fi
    echo -e "${GREEN}$cc.zone downloaded successfully.${NC}"
    return 0
}

function pre_requisites() {
    echo -e "${YELLOW}Updating packages and installing required tools...${NC}"
    apt update -y
    apt install -y ipset iptables curl
}


function install_crowdsec() {
    echo -e "${GREEN}Installing advanced Anti-DDoS (CrowdSec)...${NC}"
    curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
    apt install -y crowdsec
    systemctl enable crowdsec && systemctl start crowdsec
    cscli collections install crowdsecurity/linux
    cscli postoverflows install crowdsecurity/rdns
    cscli bouncers install crowdsec-firewall-bouncer-iptables
    systemctl restart crowdsec
    echo -e "${GREEN}CrowdSec Anti-DDoS Installed Successfully.${NC}"
    press_enter
}

function uninstall_crowdsec() {
    echo -e "${YELLOW}Removing CrowdSec Anti-DDoS...${NC}"
    systemctl stop crowdsec
    systemctl disable crowdsec
    apt purge -y crowdsec crowdsec-firewall-bouncer-iptables
    rm -rf /etc/crowdsec
    echo -e "${GREEN}CrowdSec completely removed.${NC}"
    press_enter
}

function ban_country_request() {
    read -p "Enter 2-letter country code to block (e.g., ru): " cc
    cc="${cc,,}"

    if [[ ! -f "$COUNTRY_DIR/$cc.zone" ]]; then
        echo -e "${YELLOW}File $cc.zone not found locally. Downloading...${NC}"
        download_country_file "$cc"
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}Cannot proceed without $cc.zone file.${NC}"
            press_enter
            return
        fi
    fi

    ipset destroy ${cc}_set 2>/dev/null
    ipset create ${cc}_set hash:net

    while read -r ip; do
        ipset add -exist ${cc}_set "$ip"
    done < "$COUNTRY_DIR/$cc.zone"

    if ! iptables -C INPUT -m set --match-set ${cc}_set src -j DROP &>/dev/null; then
        iptables -I INPUT -m set --match-set ${cc}_set src -j DROP
    fi

    echo -e "${GREEN}Incoming traffic from country '$cc' banned successfully.${NC}"
    press_enter
}


function ban_country_connect() {
    read -p "Enter 2-letter country code to block outgoing (e.g., ru): " cc
    cc="${cc,,}"

    if [[ ! -f "$COUNTRY_DIR/$cc.zone" ]]; then
        echo -e "${YELLOW}File $cc.zone not found locally. Downloading...${NC}"
        download_country_file "$cc"
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}Cannot proceed without $cc.zone file.${NC}"
            press_enter
            return
        fi
    fi

    ipset destroy ${cc}_out 2>/dev/null
    ipset create ${cc}_out hash:net

    while read -r ip; do
        ipset add -exist ${cc}_out "$ip"
    done < "$COUNTRY_DIR/$cc.zone"

    if ! iptables -C OUTPUT -m set --match-set ${cc}_out dst -j DROP &>/dev/null; then
        iptables -I OUTPUT -m set --match-set ${cc}_out dst -j DROP
    fi

    echo -e "${GREEN}Outgoing traffic to country '$cc' banned successfully.${NC}"
    press_enter
}


function unban_country() {
    read -p "Enter 2-letter country code to unban (e.g., ru): " cc
    cc="${cc,,}"
    echo -e "${YELLOW}Removing incoming ban for country '$cc'...${NC}"
    while iptables -C INPUT -m set --match-set ${cc}_set src -j DROP &>/dev/null; do
        iptables -D INPUT -m set --match-set ${cc}_set src -j DROP
    done
    ipset destroy ${cc}_set 2>/dev/null
    echo -e "${YELLOW}Removing outgoing ban for country '$cc'...${NC}"
    while iptables -C OUTPUT -m set --match-set ${cc}_out dst -j DROP &>/dev/null; do
        iptables -D OUTPUT -m set --match-set ${cc}_out dst -j DROP
    done
    ipset destroy ${cc}_out 2>/dev/null
    echo -e "${GREEN}Country '$cc' unbanned completely.${NC}"
    press_enter
}

function optimize_network() {
    echo -e "${CYAN}Installing BBR + FQ_CoDel and setting DNS...${NC}"
    modprobe tcp_bbr
    if ! grep -q "tcp_bbr" /etc/modules-load.d/modules.conf 2>/dev/null; then
        echo "tcp_bbr" >> /etc/modules-load.d/modules.conf
    fi
    sysctl -w net.ipv4.tcp_congestion_control=bbr
    sysctl -w net.core.default_qdisc=fq_codel

    echo -e "${YELLOW}Choose DNS:${NC}"
    echo -e "${RED}1. ${CYAN}Google${NC}"
    echo -e "${RED}2. ${CYAN}Cloudflare${NC}"
    echo -e "${RED}3. ${CYAN}Quad9${NC}"
    echo -e "${RED}4. ${CYAN}403 Online (Anti Sanction)${NC}"
    read -p "Select DNS: " dns_choice

    case $dns_choice in
        1) dns_servers="nameserver 8.8.8.8\nnameserver 8.8.4.4";;
        2) dns_servers="nameserver 1.1.1.1\nnameserver 1.1.1.2";;
        3) dns_servers="nameserver 9.9.9.9\nnameserver 149.112.112.112";;
        4) dns_servers="nameserver 10.202.10.202\nnameserver 10.202.10.102";;
        *) echo -e "${RED}Invalid choice, setting Google DNS by default.${NC}"
           dns_servers="nameserver 8.8.8.8\nnameserver 8.8.4.4";;
    esac

    echo -e -n "$dns_servers" > /etc/resolv.conf
    echo -e "${GREEN}Network optimized with BBR + FQ_CoDel and new DNS.${NC}"
    press_enter
}

function set_mtu() {
    read -p "Enter MTU value (e.g., 1400): " mtu
    ip link | awk -F": " '/^[0-9]+: / {print $2}' | while read iface; do
        ip link set dev $iface mtu $mtu 2>/dev/null
    done
    echo -e "${GREEN}MTU set to $mtu for all interfaces.${NC}"
    press_enter
}

function ban_ip() {
    read -p "Enter IP to ban: " ip
    iptables -I INPUT -s $ip -j DROP
    iptables -I OUTPUT -d $ip -j DROP
    echo -e "${GREEN}IP $ip fully blocked.${NC}"
    press_enter
}

function unban_ip() {
    read -p "Enter IP to unban: " ip
    iptables -D INPUT -s $ip -j DROP 2>/dev/null
    iptables -D OUTPUT -d $ip -j DROP 2>/dev/null
    echo -e "${GREEN}IP $ip unblocked.${NC}"
    press_enter
}

function swap_maker() {
    echo -e "${YELLOW}Select swap size:${NC}"
    echo -e "${RED}1. 512MB\n2. 1GB\n3. 2GB\n4. 4GB\n5. Manual\n6. No swap"
    read -p "Choice: " ch
    case $ch in
        1) swap_size="512M";;
        2) swap_size="1G";;
        3) swap_size="2G";;
        4) swap_size="4G";;
        5) read -p "Enter size (e.g., 300M, 1G): " swap_size;;
        6) echo "Skipping swap..."; press_enter; return;;
        *) echo -e "${RED}Invalid choice!${NC}"; press_enter; return;;
    esac

    swapoff -a
    rm -f /swapfile
    dd if=/dev/zero of=/swapfile bs=1M count=$(echo $swap_size | grep -o -E '[0-9]+') status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    if ! grep -q "/swapfile" /etc/fstab 2>/dev/null; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    sysctl vm.swappiness=10
    if ! grep -q "vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
        echo 'vm.swappiness=10' >> /etc/sysctl.conf
    fi

    echo -e "${GREEN}Swap configured with $swap_size${NC}"
    press_enter
}

function block_porn() {
    echo -e "${CYAN}Blocking Porn Sites via DNS...${NC}"
    echo -e "nameserver 94.140.14.15\nnameserver 94.140.15.16" > /etc/resolv.conf
    echo -e "${GREEN}Porn content blocked using DNS filtering.${NC}"
    press_enter
}

# شروع اسکریپت

pre_requisites

while true; do
    clear
    logo
    echo -e "\n${YELLOW}Select an option:${NC}"
    echo -e "${GREEN}1.${NC} Install Anti-DDoS (CrowdSec)"
    echo -e "${GREEN}2.${NC} Ban Country (Incoming)"
    echo -e "${GREEN}3.${NC} Ban Country (Outgoing)"
    echo -e "${GREEN}4.${NC} Unban Country"
    echo -e "${GREEN}5.${NC} Optimize Server Network (BBR + DNS)"
    echo -e "${GREEN}6.${NC} Set MTU"
    echo -e "${GREEN}7.${NC} Ban an IP"
    echo -e "${GREEN}8.${NC} Unban an IP"
    echo -e "${GREEN}9.${NC} Create Virtual RAM (Swap)"
    echo -e "${GREEN}10.${NC} Block Adult Content"
    echo -e "${GREEN}11.${NC} Remove Anti-DDoS System"
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
        0) echo -e "${YELLOW}Exiting... Bye!${NC}"; exit 0;;
        *) echo -e "${RED}Invalid option! Try again.${NC}"; press_enter;;
    esac
done
