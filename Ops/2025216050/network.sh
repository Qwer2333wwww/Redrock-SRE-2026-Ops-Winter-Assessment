#!/bin/bash

# 网络设备
ETH_DEV="eth0"

# 静态 IP 配置参数
STATIC_IP="172.22.146.150"
NETMASK="24"
GATEWAY="172.22.146.1"

# DNS 配置
DNS1="172.22.146.53"
DNS2="172.22.146.54"

# 内网网段
LOCAL_NETWORK="172.22.146.0/24"
INTERNAL_NETWORK="172.16.0.0/12"

# 文件路径
LOG_FILE="/var/log/network_config.log"
BACKUP_DIR="/var/backup/network"
RESOLV_FILE="/etc/resolv.conf"

log() {
    TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$TIMESTAMP] $1" >> "$LOG_FILE"
    echo "[$TIMESTAMP] $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log "请使用 root 权限运行此脚本"
        exit 1
    fi
}

backup_config() {
    mkdir -p "$BACKUP_DIR"
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

    # 备份当前 IP 配置
    ip addr show "$ETH_DEV" > "$BACKUP_DIR/ip_addr_$TIMESTAMP.bak"
    
    # 备份当前路由表
    ip route show > "$BACKUP_DIR/ip_route_$TIMESTAMP.bak"

    # 备份当前 DNS 配置
    cp "$RESOLV_FILE" "$BACKUP_DIR/resolv_$TIMESTAMP.bak"
    
    # 记录当前模式
    if pgrep dhclient > /dev/null; then
        echo "dhcp" > "$BACKUP_DIR/mode_$TIMESTAMP.bak"
    else
        echo "static" > "$BACKUP_DIR/mode_$TIMESTAMP.bak"
    fi

    log "[info] 已备份当前网络配置到 $BACKUP_DIR"
}

configure_dhcp() {
    log "[info] 配置网络为 DHCP 模式"
 
    pkill dhclient
    sleep 2
    ip addr flush dev "$ETH_DEV"
    
    dhclient "$ETH_DEV"

    if [ $? -eq 0 ]; then
        log "[info] DHCP 配置成功"
    else
        log "[error] DHCP 配置失败"
    fi
    
    ip addr show "$ETH_DEV" >> "$LOG_FILE"
    ip route show >> "$LOG_FILE"
}

configure_static() {
    log "[info] 配置网络为静态 IP 模式"
    
    pkill dhclient
    sleep 2
    ip addr flush dev "$ETH_DEV"

    ip addr add "$STATIC_IP/$NETMASK" dev "$ETH_DEV"
    ip link set "$ETH_DEV" up
    ip route add default via "$GATEWAY" dev "$ETH_DEV"
    echo -e "nameserver $DNS1\nnameserver $DNS2" > "$RESOLV_FILE"
    
    if ip addr show "$ETH_DEV" | grep -q "$STATIC_IP"; then
        log "[info] 静态 IP 配置成功"
    else
        log "[error] 静态 IP 配置失败"
    fi
    
    ip addr show "$ETH_DEV" >> "$LOG_FILE"
    ip route show >> "$LOG_FILE"
}

rollback() {
    LATEST_BACKUP=$(ls -t "$BACKUP_DIR"/mode_*.bak | head -n 1)
    if [ -z "$LATEST_BACKUP" ]; then
        log "[error] 未找到备份文件，无法回滚"
        exit 1
    fi

    MODE=$(cat "$LATEST_BACKUP")
    log "[info] 回滚到上次配置模式: $MODE"

    if [ "$MODE" == "dhcp" ]; then
        configure_dhcp
    else
        configure_static
    fi
}

usage() {
    cat << EOF
用法: ./network.sh [选项]

选项:
    dhcp      - 配置为办公网络模式(DHCP自动获取)
    static    - 配置为生产网络模式(静态IP)
    rollback  - 回滚到上一次的配置

示例:
    ./network.sh dhcp
    ./network.sh static
EOF
}

main() {
    check_root
    backup_config

    case "$1" in
        dhcp)
            configure_dhcp
            ;;
        static)
            configure_static
            ;;
        rollback)
            rollback
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"