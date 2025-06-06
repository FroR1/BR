#!/bin/bash

# Скрипт для настройки маршрутизатора BR-RTR

# Установка зависимостей при запуске скрипта
install_dependencies() {
    echo "Установка зависимостей..."
    apt-get update
    apt-get install -y iproute2 nftables systemd frr
    echo "Зависимости установлены."
}

# Вызов установки зависимостей
install_dependencies

# Начальные значения переменных
INTERFACE_ISP="ens192"
INTERFACE_LAN="ens224"
IP_ISP="172.16.5.2/28"
IP_LAN="192.168.1.1/27"
DEFAULT_GW="172.16.5.1"
HOSTNAME="br-rtr.au-team.irpo"
TIME_ZONE="Asia/Novosibirsk"
USERNAME="net_admin"
UID=1010
PASSWORD="P@$$word"
BANNER_TEXT="Authorized access only"
TUNNEL_LOCAL_IP="172.16.5.2"  # IP BR-RTR к ISP
TUNNEL_REMOTE_IP="172.16.4.2" # IP HQ-RTR к ISP
TUNNEL_IP="172.16.100.2/28"   # IP для туннеля на BR-RTR
TUNNEL_NAME="gre1"

# Функция проверки существования интерфейса
check_interface() {
    if ! ip link show "$1" &> /dev/null; then
        echo "Ошибка: Интерфейс $1 не существует."
        exit 1
    fi
}

# Функция для вычисления сети из IP и маски
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

# Функция настройки сетевых интерфейсов через /etc/net/ifaces/
configure_interfaces() {
    echo "Настройка интерфейсов через /etc/net/ifaces/..."
    
    # Настройка интерфейса ISP
    mkdir -p /etc/net/ifaces/"$INTERFACE_ISP"
    cat > /etc/net/ifaces/"$INTERFACE_ISP"/options << EOF
BOOTPROTO=dhcp
TYPE=eth
DISABLED=no
CONFIG_IPV4=yes
EOF
    ip addr flush dev "$INTERFACE_ISP"
    ip link set "$INTERFACE_ISP" up
    
    # Настройка интерфейса LAN
    mkdir -p /etc/net/ifaces/"$INTERFACE_LAN"
    cat > /etc/net/ifaces/"$INTERFACE_LAN"/options << EOF
BOOTPROTO=static
TYPE=eth
DISABLED=no
CONFIG_IPV4=yes
EOF
    echo "$IP_LAN" > /etc/net/ifaces/"$INTERFACE_LAN"/ipv4address
    
    # Настройка шлюза
    echo "GATEWAY=$DEFAULT_GW" > /etc/net/ifaces/"$INTERFACE_LAN"/gateway
    
    # Перезапуск службы network
    systemctl restart network
    echo "Интерфейсы настроены."
}

# Функция настройки GRE-туннеля через /etc/net/ifaces/
configure_tunnel() {
    echo "Настройка GRE-туннеля через /etc/net/ifaces/..."
    
    # Настройка туннеля
    ip tunnel add "$TUNNEL_NAME" mode gre local "$TUNNEL_LOCAL_IP" remote "$TUNNEL_REMOTE_IP" ttl 64
    ip addr add "$TUNNEL_IP" dev "$TUNNEL_NAME"
    ip link set "$TUNNEL_NAME" up
    
    # Сохранение конфигурации туннеля
    mkdir -p /etc/net/ifaces/"$TUNNEL_NAME"
    cat > /etc/net/ifaces/"$TUNNEL_NAME"/options << EOF
BOOTPROTO=static
TYPE=tunnel
DISABLED=no
CONFIG_IPV4=yes
TUNNEL_TYPE=gre
TUNNEL_LOCAL="$TUNNEL_LOCAL_IP"
TUNNEL_REMOTE="$TUNNEL_REMOTE_IP"
TUNNEL_TTL=64
EOF
    echo "$TUNNEL_IP" > /etc/net/ifaces/"$TUNNEL_NAME"/ipv4address
    
    # Перезапуск службы network
    systemctl restart network
    echo "GRE-туннель настроен."
}

# Функция настройки nftables и IP forwarding
configure_nftables() {
    echo "Настройка nftables и IP forwarding..."
    
    # Установка nftables, если отсутствует
    if ! dpkg -l | grep -q "nftables"; then
        echo "Установка пакета nftables..."
        apt-get update
        apt-get install -y nftables
    fi
    
    LAN_NETWORK=$(get_network "$IP_LAN")
    
    # Включение IP forwarding
    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ip-forward.conf
    
    # Создание конфигурации nftables
    cat > /etc/nftables.conf << EOF
#!/usr/sbin/nft -f
flush ruleset

table inet nat {
    chain prerouting {
        type nat hook prerouting priority 0; policy accept;
    }
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        ip saddr $LAN_NETWORK oifname "$INTERFACE_ISP" counter masquerade
    }
}
EOF
    
    # Применение конфигурации
    nft -f /etc/nftables.conf
    systemctl enable nftables
    systemctl restart nftables
    
    echo "nftables и IP forwarding настроены."
}

# Функция установки hostname
set_hostname() {
    echo "Установка hostname..."
    hostnamectl set-hostname "$HOSTNAME"
    echo "Hostname установлен: $HOSTNAME"
}

# Функция установки часового пояса
set_timezone() {
    echo "Установка часового пояса..."
    timedatectl set-timezone "$TIME_ZONE"
    echo "Часовой пояс установлен: $TIME_ZONE"
}

# Функция создания пользователя
configure_user() {
    echo "Создание пользователя $USERNAME..."
    if id "$USERNAME" &> /dev/null; then
        echo "Пользователь $USERNAME уже существует."
    else
        useradd -m -u "$UID" -s /bin/bash "$USERNAME"
        echo "$USERNAME:$PASSWORD" | chpasswd
        echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/"$USERNAME"
        chmod 0440 /etc/sudoers.d/"$USERNAME"
        echo "Пользователь $USERNAME создан с UID $UID и правами sudo."
    fi
}

# Функция настройки баннера
configure_banner() {
    echo "Настройка баннера..."
    echo "$BANNER_TEXT" > /etc/issue
    echo "Баннер настроен."
}

# Функция настройки OSPF
configure_ospf() {
    echo "Настройка OSPF..."
    
    # Активация OSPF в FRR
    sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
    systemctl enable --now frr
    
    # Настройка через vtysh
    vtysh << EOF
configure terminal
router ospf
passive-interface default
network 172.16.100.0/28 area 0
network 192.168.1.0/27 area 0
exit
interface $TUNNEL_NAME
no ip ospf passive
ip ospf authentication-key PLAINPAS
ip ospf authentication
exit
do wr mem
exit
EOF
    
    echo "OSPF настроен."
}

# Функция редактирования данных
edit_data() {
    while true; do
        clear
        echo "Текущие значения:"
        echo "1. Интерфейс к ISP: $INTERFACE_ISP"
        echo "2. Интерфейс к LAN: $INTERFACE_LAN"
        echo "3. IP для ISP: $IP_ISP"
        echo "4. IP для LAN: $IP_LAN"
        echo "5. Шлюз по умолчанию: $DEFAULT_GW"
        echo "6. Hostname: $HOSTNAME"
        echo "7. Часовой пояс: $TIME_ZONE"
        echo "8. Имя пользователя: $USERNAME"
        echo "9. UID пользователя: $UID"
        echo "10. Пароль пользователя: $PASSWORD"
        echo "11. Текст баннера: $BANNER_TEXT"
        echo "12. Локальный IP для туннеля(IP интерфейса ens192 Этого устройства который с ISP): $TUNNEL_LOCAL_IP"
        echo "13. Удаленный IP для туннеля(IP интерфейса ens192 Другого устройства который с ISP): $TUNNEL_REMOTE_IP"
        echo "14. IP для туннеля: $TUNNEL_IP"
        echo "0. Назад"
        echo "Введите номер параметра для изменения (или 0 для выхода):"
        read choice
        case $choice in
            1) read -p "Новый интерфейс к ISP [$INTERFACE_ISP]: " input
               INTERFACE_ISP=${input:-$INTERFACE_ISP} ;;
            2) read -p "Новый интерфейс к LAN [$INTERFACE_LAN]: " input
               INTERFACE_LAN=${input:-$INTERFACE_LAN} ;;
            3) read -p "Новый IP для ISP [$IP_ISP]: " input
               IP_ISP=${input:-$IP_ISP} ;;
            4) read -p "Новый IP для LAN [$IP_LAN]: " input
               IP_LAN=${input:-$IP_LAN} ;;
            5) read -p "Новый шлюз по умолчанию [$DEFAULT_GW]: " input
               DEFAULT_GW=${input:-$DEFAULT_GW} ;;
            6) read -p "Новый hostname [$HOSTNAME]: " input
               HOSTNAME=${input:-$HOSTNAME} ;;
            7) read -p "Новый часовой пояс [$TIME_ZONE]: " input
               TIME_ZONE=${input:-$TIME_ZONE} ;;
            8) read -p "Новое имя пользователя [$USERNAME]: " input
               USERNAME=${input:-$USERNAME} ;;
            9) read -p "Новый UID пользователя [$UID]: " input
               UID=${input:-$UID} ;;
            10) read -p "Новый пароль пользователя [$PASSWORD]: " input
                PASSWORD=${input:-$PASSWORD} ;;
            11) read -p "Новый текст баннера [$BANNER_TEXT]: " input
                BANNER_TEXT=${input:-$BANNER_TEXT} ;;
            12) read -p "Новый локальный IP для туннеля [$TUNNEL_LOCAL_IP]: " input
                TUNNEL_LOCAL_IP=${input:-$TUNNEL_LOCAL_IP} ;;
            13) read -p "Новый удаленный IP для туннеля [$TUNNEL_REMOTE_IP]: " input
                TUNNEL_REMOTE_IP=${input:-$TUNNEL_REMOTE_IP} ;;
            14) read -p "Новый IP для туннеля [$TUNNEL_IP]: " input
                TUNNEL_IP=${input:-$TUNNEL_IP} ;;
            0) return ;;
            *) echo "Неверный выбор." ;;
        esac
    done
}

# Основное меню
while true; do
    clear
    echo -e "\nМеню настройки BR-RTR:"
    echo "1. Редактировать данные"
    echo "2. Настроить сетевые интерфейсы"
    echo "3. Настроить NAT и IP forwarding"
    echo "4. Настроить GRE-туннель"
    echo "5. Настроить OSPF"
    echo "6. Установить hostname"
    echo "7. Установить часовой пояс"
    echo "8. Настроить пользователя"
    echo "9. Настроить баннер"
    echo "10. Выполнить все настройки"
    echo "0. Выход"
    read -p "Выберите опцию: " option
    
    case $option in
        1) edit_data ;;
        2) configure_interfaces ;;
        3) configure_nftables ;;
        4) configure_tunnel ;;
        5) configure_ospf ;;
        6) set_hostname ;;
        7) set_timezone ;;
        8) configure_user ;;
        9) configure_banner ;;
        10) 
            configure_interfaces
            configure_nftables
            configure_tunnel
            configure_ospf
            set_hostname
            set_timezone
            configure_user
            configure_banner
            echo "Все настройки выполнены."
            ;;
        0) echo "Выход."; exit 0 ;;
        *) echo "Неверный выбор." ;;
    esac
done
