#!/bin/bash

# Скрипт для настройки маршрутизатора BR-RTR

# Начальные значения переменных
INTERFACE_ISP="ens192"
INTERFACE_LAN="ens224"
IP_ISP="172.16.5.2/28"
IP_LAN="192.168.1.1/27"
DEFAULT_GW="172.16.5.1"
HOSTNAME="br-rtr.au-team.irpo"
TIME_ZONE="Asia/Novosibirsk"

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

# Функция настройки сетевых интерфейсов
configure_interfaces() {
    echo "Настройка интерфейсов..."
    check_interface "$INTERFACE_ISP"
    check_interface "$INTERFACE_LAN"
    
    ip addr flush dev "$INTERFACE_ISP"
    ip addr add "$IP_ISP" dev "$INTERFACE_ISP"
    ip link set "$INTERFACE_ISP" up
    
    ip addr flush dev "$INTERFACE_LAN"
    ip addr add "$IP_LAN" dev "$INTERFACE_LAN"
    ip link set "$INTERFACE_LAN" up
    
    ip route flush default
    ip route add default via "$DEFAULT_GW" dev "$INTERFACE_ISP"
    
    echo "Интерфейсы настроены."
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

# Функция создания пользователя net_admin
configure_user() {
    echo "Создание пользователя net_admin..."
    if id "net_admin" &> /dev/null; then
        echo "Пользователь net_admin уже существует."
    else
        useradd -m -u 1010 -s /bin/bash net_admin
        echo "net_admin:P@$$word" | chpasswd
        echo "net_admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/net_admin
        chmod 0440 /etc/sudoers.d/net_admin
        echo "Пользователь net_admin создан с максимальными привилегиями."
    fi
}

# Функция редактирования данных
edit_data() {
    echo "Текущие значения:"
    echo "1. Интерфейс к ISP: $INTERFACE_ISP"
    echo "2. Интерфейс к LAN: $INTERFACE_LAN"
    echo "3. IP для ISP: $IP_ISP"
    echo "4. IP для LAN: $IP_LAN"
    echo "5. Шлюз по умолчанию: $DEFAULT_GW"
    echo "6. Hostname: $HOSTNAME"
    echo "7. Часовой пояс: $TIME_ZONE"
    echo "Введите номер параметра для изменения (или 0 для выхода):"
    read choice
    case $choice in
        1) read -p "Новый интерфейс к ISP: " INTERFACE_ISP ;;
        2) read -p "Новый интерфейс к LAN: " INTERFACE_LAN ;;
        3) read -p "Новый IP для ISP (например, 172.16.5.2/28): " IP_ISP ;;
        4) read -p "Новый IP для LAN (например, 192.168.1.1/27): " IP_LAN ;;
        5) read -p "Новый шлюз по умолчанию: " DEFAULT_GW ;;
        6) read -p "Новый hostname: " HOSTNAME ;;
        7) read -p "Новый часовой пояс: " TIME_ZONE ;;
        0) return ;;
        *) echo "Неверный выбор." ;;
    esac
}

# Основное меню
while true; do
    echo -e "\nМеню настройки BR-RTR:"
    echo "1. Редактировать данные"
    echo "2. Настроить сетевые интерфейсы"
    echo "3. Настроить NAT и IP forwarding"
    echo "4. Установить hostname"
    echo "5. Установить часовой пояс"
    echo "6. Настроить пользователя net_admin"
    echo "7. Выполнить все настройки"
    echo "8. Выход"
    read -p "Выберите опцию: " option
    
    case $option in
        1) edit_data ;;
        2) configure_interfaces ;;
        3) configure_nftables ;;
        4) set_hostname ;;
        5) set_timezone ;;
        6) configure_user ;;
        7) 
            configure_interfaces
            configure_nftables
            set_hostname
            set_timezone
            configure_user
            echo "Все настройки выполнены."
            ;;
        8) echo "Выход."; exit 0 ;;
        *) echo "Неверный выбор." ;;
    esac
done
