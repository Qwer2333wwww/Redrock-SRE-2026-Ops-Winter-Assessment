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
    local level="$1"
    local message="$2"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log "ERROR" "请使用 root 权限运行此脚本"
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

    log "INFO" "已备份当前网络配置到 $BACKUP_DIR"
}

configure_dhcp() {
    log "INFO" "配置网络为 DHCP 模式"
 
    pkill dhclient 2>/dev/null
    sleep 2
    ip addr flush dev "$ETH_DEV"
    
    dhclient "$ETH_DEV"
    sleep 3

    if ip addr show "$ETH_DEV" | grep -q "inet "; then
        log "INFO" "DHCP 配置成功"
    else
        log "ERROR" "DHCP 配置失败"
    fi
    
    ip addr show "$ETH_DEV" >> "$LOG_FILE"
    ip route show >> "$LOG_FILE"
}

configure_static() {
    log "INFO" "配置网络为静态 IP 模式"
    
    pkill dhclient 2>/dev/null
    sleep 2
    ip addr flush dev "$ETH_DEV"

    ip addr add "$STATIC_IP/$NETMASK" dev "$ETH_DEV"
    ip link set "$ETH_DEV" up
    
    ip route del default 2>/dev/null
    ip route add default via "$GATEWAY" dev "$ETH_DEV"
    
    [ -L "$RESOLV_FILE" ] && rm -f "$RESOLV_FILE"
    echo -e "nameserver $DNS1\nnameserver $DNS2" > "$RESOLV_FILE"
    
    if ip addr show "$ETH_DEV" | grep -q "$STATIC_IP"; then
        log "INFO" "静态 IP 配置成功"
    else
        log "ERROR" "静态 IP 配置失败"
    fi
    
    ip addr show "$ETH_DEV" >> "$LOG_FILE"
    ip route show >> "$LOG_FILE"
}

rollback() {
    LATEST_BACKUP=$(ls -t "$BACKUP_DIR"/mode_*.bak 2>/dev/null | head -n 1)
    if [ -z "$LATEST_BACKUP" ]; then
        log "ERROR" "未找到备份文件，无法回滚"
        exit 1
    fi

    MODE=$(cat "$LATEST_BACKUP")
    log "INFO" "回滚到上次配置模式: $MODE"

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
    
    case "$1" in
        dhcp)
            backup_config
            configure_dhcp
            ;;
        static)
            backup_config
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
