#!/bin/bash

# Script for configuring BR-RTR

# Install dependencies at script start
install_dependencies() {
    echo "Installing dependencies..."
    apt-get update
    apt-get install -y iproute2 nftables systemd frr mc wget openssh-server iputils-ping
    echo "Dependencies installed."
}

install_dependencies

# Initial variable values (Variant 7 from Ответы.txt)
INTERFACE_ISP="ens192"
INTERFACE_LAN="ens224"
IP_ISP="172.16.19.2/28"
IP_LAN="10.1.1.1/27"
DEFAULT_GW="172.16.19.1"
HOSTNAME="br-rtr.au-team.irpo"
TIME_ZONE="Asia/Novosibirsk"
USERNAME="net_admin"
UID=1065
PASSWORD="P@$$word"
BANNER_TEXT="Authorized access only"
TUNNEL_LOCAL_IP="172.16.19.2"  # BR-RTR IP to ISP
TUNNEL_REMOTE_IP="172.16.18.2" # HQ-RTR IP to ISP
TUNNEL_IP="172.16.100.2/28"   # Tunnel IP for BR-RTR
TUNNEL_NAME="tun1"

# Function to check interface existence
check_interface() {
    if ! ip link show "$1" &> /dev/null; then
        echo "Error: Interface $1 does not exist."
        return 1
    fi
    return 0
}

# Function to calculate network from IP and mask
get_network() {
    local ip_mask=$1
    local ip=$(echo "$ip_mask" | cut -d'/' -f1)
    local mask=$(echo "$ip_mask" | cut -d'/' -f2)
    local IFS='.'
    read -r i1 i2 i3 i4 <<< "$ip"
    local bits=$((32 - mask))
    local net=$(( (i1 << 24) + (i2 << 16) + (i3 << 8) + i4 ))
    local net=$(( net >> bits << bits ))
    echo "$(( (net >> 24) & 255 )).$(( (net >> 16) & 255 )).$(( (net >> 8) & 255 )).$(( net & 255 ))/$mask"
}

# Function to check interface status with ping
check_interface_status() {
    echo "Checking interface status..."
    local status=0
    local green=$(tput setaf 2; tput blink)
    local red=$(tput setaf 1; tput blink)
    local reset=$(tput sgr0)

    # Check ISP interface
    if check_interface "$INTERFACE_ISP"; then
        if ping -c 2 -W 1 "$DEFAULT_GW" &> /dev/null; then
            echo "${green}Interface $INTERFACE_ISP is UP${reset}"
        else
            echo "${red}Interface $INTERFACE_ISP is DOWN${reset}"
            status=1
        fi
    else
        echo "${red}Interface $INTERFACE_ISP does not exist${reset}"
        status=1
    fi

    # Check LAN interface
    if check_interface "$INTERFACE_LAN"; then
        local lan_next_hop=$(echo "$IP_LAN" | cut -d'/' -f1 | awk -F. '{print $1"."$2"."$3"."($4+1)}')
        if ping -c 2 -W 1 "$lan_next_hop" &> /dev/null; then
            echo "${green}Interface $INTERFACE_LAN is UP${reset}"
        else
            echo "${red}Interface $INTERFACE_LAN is DOWN${reset}"
            status=1
        fi
    else
        echo "${red}Interface $INTERFACE_LAN does not exist${reset}"
        status=1
    fi

    # Check tunnel interface
    if check_interface "$TUNNEL_NAME"; then
        if ping -c 2 -W 1 "$TUNNEL_REMOTE_IP" &> /dev/null; then
            echo "${green}Interface $TUNNEL_NAME is UP${reset}"
        else
            echo "${red}Interface $TUNNEL_NAME is DOWN${reset}"
            status=1
        fi
    else
        echo "${red}Interface $TUNNEL_NAME does not exist${reset}"
        status=1
    fi

    return $status
}

# Function to configure network interfaces via /etc/net/ifaces/
configure_interfaces() {
    echo "Configuring interfaces via /etc/net/ifaces/..."
    
    check_interface "$INTERFACE_ISP" || exit 1
    check_interface "$INTERFACE_LAN" || exit 1
    
    mkdir -p /etc/net/ifaces/"$INTERFACE_ISP"
    cat > /etc/net/ifaces/"$INTERFACE_ISP"/options << EOF
BOOTPROTO=static
TYPE=eth
DISABLED=no
CONFIG_IPV4=yes
EOF
    echo "$IP_ISP" > /etc/net/ifaces/"$INTERFACE_ISP"/ipv4address
    echo "default via $DEFAULT_GW" > /etc/net/ifaces/"$INTERFACE_ISP"/ipv4route
    
    mkdir -p /etc/net/ifaces/"$INTERFACE_LAN"
    cat > /etc/net/ifaces/"$INTERFACE_LAN"/options << EOF
BOOTPROTO=static
TYPE=eth
DISABLED=no
CONFIG_IPV4=yes
EOF
    echo "$IP_LAN" > /etc/net/ifaces/"$INTERFACE_LAN"/ipv4address
    
    systemctl restart network
    check_interface_status
    echo "Interfaces configured."
}

# Function to configure GRE tunnel via /etc/net/ifaces/
configure_tunnel() {
    echo "Configuring GRE tunnel via /etc/net/ifaces/..."
    
    modprobe gre
    
    mkdir -p /etc/net/ifaces/"$TUNNEL_NAME"
    cat > /etc/net/ifaces/"$TUNNEL_NAME"/options << EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=$TUNNEL_LOCAL_IP
TUNREMOTE=$TUNNEL_REMOTE_IP
TUNOPTIONS='ttl 64'
HOST=$INTERFACE_ISP
BOOTPROTO=static
DISABLED=no
CONFIG_IPV4=yes
EOF
    echo "$TUNNEL_IP" > /etc/net/ifaces/"$TUNNEL_NAME"/ipv4address
    
    ip link set "$TUNNEL_NAME" down 2>/dev/null || true
    ip tunnel del "$TUNNEL_NAME" 2>/dev/null || true
    ip tunnel add "$TUNNEL_NAME" mode gre local "$TUNNEL_LOCAL_IP" remote "$TUNNEL_REMOTE_IP" ttl 64
    ip addr add "$TUNNEL_IP" dev "$TUNNEL_NAME"
    ip link set "$TUNNEL_NAME" up
    
    systemctl restart network
    check_interface_status
    echo "GRE tunnel configured."
}

# Function to configure nftables and IP forwarding
configure_nftables() {
    echo "Configuring nftables and IP forwarding..."
    
    apt-get install -y nftables
    
    LAN_NETWORK=$(get_network "$IP_LAN")
    
    sysctl -w net.ipv4.ip_forward=1
    if grep -q "net.ipv4.ip_forward" /etc/net/sysctl.conf; then
        sed -i 's/net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/net/sysctl.conf
    else
        echo "net.ipv4.ip_forward=1" >> /etc/net/sysctl.conf
    fi
    
    cat > /etc/nftables/nftables.nft << EOF
#!/usr/sbin/nft -f
flush ruleset

table ip nat {
    chain postrouting {
        type nat hook postrouting priority 0; policy accept;
        ip saddr $LAN_NETWORK oifname "$INTERFACE_ISP" counter masquerade
    }
}
EOF
    
    nft -f /etc/nftables/nftables.nft
    systemctl enable --now nftables
    echo "nftables and IP forwarding configured."
}

# Function to set hostname
set_hostname() {
    echo "Setting hostname..."
    hostnamectl set-hostname "$HOSTNAME"
    echo "$HOSTNAME" > /etc/hostname
    echo "Hostname set: $HOSTNAME"
}

# Function to set timezone
set_timezone() {
    echo "Setting timezone..."
    apt-get install -y tzdata
    timedatectl set-timezone "$TIME_ZONE"
    echo "Timezone set: $TIME_ZONE"
}

# Function to configure user
configure_user() {
    echo "Creating user $USERNAME..."
    if id "$USERNAME" &> /dev/null; then
        echo "User $USERNAME already exists."
    else
        adduser "$USERNAME" -u "$UID"
        echo "$USERNAME:$PASSWORD" | chpasswd
        echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
        usermod -aG wheel "$USERNAME"
        echo "User $USERNAME created with UID $UID and sudo rights."
    fi
}

# Function to configure SSH banner
configure_ssh_banner() {
    echo "Configuring SSH banner..."
    echo "$BANNER_TEXT" > /etc/banner
    if grep -q "^Banner" /etc/openssh/sshd_config; then
        sed -i 's|^Banner.*|Banner /etc/banner|' /etc/openssh/sshd_config
    else
        echo "Banner /etc/banner" >> /etc/openssh/sshd_config
    fi
    systemctl restart sshd
    echo "SSH banner configured."
}

# Function to configure OSPF
configure_ospf() {
    echo "Configuring OSPF..."
    
    TUNNEL_NETWORK=$(get_network "$TUNNEL_IP")
    LAN_NETWORK=$(get_network "$IP_LAN")
    
    if grep -q "ospfd=no" /etc/frr/daemons; then
        sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
    elif ! grep -q "ospfd=yes" /etc/frr/daemons; then
        echo "ospfd=yes" >> /etc/frr/daemons
    fi
    systemctl enable --now frr
    
    vtysh << EOF
configure terminal
router ospf
passive-interface default
network $TUNNEL_NETWORK area 0
network $LAN_NETWORK area 0
exit
interface $TUNNEL_NAME
no ip ospf passive
ip ospf authentication-key PLAINPAS
ip ospf authentication
exit
do wr mem
exit
EOF
    
    systemctl restart network
    echo "OSPF configured."
}

# Function to configure additional network interface
configure_additional_interface() {
    echo "Configuring additional network interface..."
    read -p "Enter interface name (e.g., ens256): " new_interface
    read -p "Enter IP address with mask (e.g., 192.168.1.1/24): " new_ip
    
    if check_interface "$new_interface"; then
        mkdir -p /etc/net/ifaces/"$new_interface"
        cat > /etc/net/ifaces/"$new_interface"/options << EOF
BOOTPROTO=static
TYPE=eth
DISABLED=no
CONFIG_IPV4=yes
EOF
        echo "$new_ip" > /etc/net/ifaces/"$new_interface"/ipv4address
        systemctl restart network
        check_interface_status
        echo "Additional interface $new_interface configured."
    else
        echo "Error: Interface $new_interface does not exist."
        exit 1
    fi
}

# Function to edit data
edit_data() {
    while true; do
        clear
        echo "Current values:"
        echo "1. ISP Interface: $INTERFACE_ISP"
        echo "2. LAN Interface: $INTERFACE_LAN"
        echo "3. ISP IP: $IP_ISP"
        echo "4. LAN IP: $IP_LAN"
        echo "5. Default Gateway: $DEFAULT_GW"
        echo "6. Hostname: $HOSTNAME"
        echo "7. Time Zone: $TIME_ZONE"
        echo "8. Username: $USERNAME"
        echo "9. User UID: $UID"
        echo "10. User Password: $PASSWORD"
        echo "11. Banner Text: $BANNER_TEXT"
        echo "12. Tunnel Local IP: $TUNNEL_LOCAL_IP"
        echo "13. Tunnel Remote IP: $TUNNEL_REMOTE_IP"
        echo "14. Tunnel IP: $TUNNEL_IP"
        echo "0. Back"
        echo "Enter parameter number to change (or 0 to exit):"
        read choice
        case $choice in
            1) read -p "New ISP interface [$INTERFACE_ISP]: " input
               INTERFACE_ISP=${input:-$INTERFACE_ISP} ;;
            2) read -p "New LAN interface [$INTERFACE_LAN]: " input
               INTERFACE_LAN=${input:-$INTERFACE_LAN} ;;
            3) read -p "New ISP IP [$IP_ISP]: " input
               IP_ISP=${input:-$IP_ISP} ;;
            4) read -p "New LAN IP [$IP_LAN]: " input
               IP_LAN=${input:-$IP_LAN} ;;
            5) read -p "New default gateway [$DEFAULT_GW]: " input
               DEFAULT_GW=${input:-$DEFAULT_GW} ;;
            6) read -p "New hostname [$HOSTNAME]: " input
               HOSTNAME=${input:-$HOSTNAME} ;;
            7) read -p "New time zone [$TIME_ZONE]: " input
               TIME_ZONE=${input:-$TIME_ZONE} ;;
            8) read -p "New username [$USERNAME]: " input
               USERNAME=${input:-$USERNAME} ;;
            9) read -p "New user UID [$UID]: " input
               UID=${input:-$UID} ;;
            10) read -p "New user password [$PASSWORD]: " input
                PASSWORD=${input:-$PASSWORD} ;;
            11) read -p "New banner text [$BANNER_TEXT]: " input
                BANNER_TEXT=${input:-$BANNER_TEXT} ;;
            12) read -p "New tunnel local IP [$TUNNEL_LOCAL_IP]: " input
                TUNNEL_LOCAL_IP=${input:-$TUNNEL_LOCAL_IP} ;;
            13) read -p "New tunnel remote IP [$TUNNEL_REMOTE_IP]: " input
                TUNNEL_REMOTE_IP=${input:-$TUNNEL_REMOTE_IP} ;;
            14) read -p "New tunnel IP [$TUNNEL_IP]: " input
                TUNNEL_IP=${input:-$TUNNEL_IP} ;;
            0) return ;;
            *) echo "Invalid choice." ;;
        esac
    done
}

# Main menu
while true; do
    clear
    echo -e "\nBR-RTR Configuration Menu:"
    echo "1. Edit data"
    echo "2. Configure network interfaces"
    echo "3. Configure NAT and IP forwarding"
    echo "4. Configure GRE tunnel"
    echo "5. Configure OSPF"
    echo "6. Set hostname"
    echo "7. Set timezone"
    echo "8. Configure user"
    echo "9. Configure SSH banner"
    echo "10. Perform all configurations"
    echo "11. Configure additional network interface"
    echo "0. Exit"
    read -p "Select an option: " option
    
    case $option in
        1) edit_data ;;
        2) configure_interfaces ;;
        3) configure_nftables ;;
        4) configure_tunnel ;;
        5) configure_ospf ;;
        6) set_hostname ;;
        7) set_timezone ;;
        8) configure_user ;;
        9) configure_ssh_banner ;;
        10) 
            configure_interfaces
            configure_nftables
            configure_tunnel
            configure_ospf
            set_hostname
            set_timezone
            configure_user
            configure_ssh_banner
            echo "All configurations completed."
            ;;
        11) configure_additional_interface ;;
        0) echo "Exiting."; exit 0 ;;
        *) echo "Invalid choice." ;;
    esac
done
