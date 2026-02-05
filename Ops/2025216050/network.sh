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
        echo "请使用 root 权限运行此脚本"
        exit 1
    fi
}

backup_config() {
    mkdir -p "$BACKUP_DIR"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    
    ip addr show "$ETH_DEV" > "$BACKUP_DIR/ip_addr_$timestamp.bak" 2>&1
    if [ ! -s "$BACKUP_DIR/ip_addr_$timestamp.bak" ]; then
        log "WARNING" "IP 备份为空(exit=$?), 回滚可能无法恢复 IP"
    fi
    
    ip route show > "$BACKUP_DIR/ip_route_$timestamp.bak" 2>&1
    if [ ! -s "$BACKUP_DIR/ip_route_$timestamp.bak" ]; then
        log "WARNING" "路由备份为空(exit=$?), 回滚可能无法恢复路由"
    fi
   
    if [ -f "$RESOLV_FILE" ]; then
        cp "$RESOLV_FILE" "$BACKUP_DIR/resolv_$timestamp.bak"
    else
        : > "$BACKUP_DIR/resolv_$timestamp.bak"
    fi
    if [ ! -s "$BACKUP_DIR/resolv_$timestamp.bak" ]; then
        log "WARNING" "DNS 备份为空，回滚可能无法恢复 DNS"
    fi
   
    if pgrep dhclient > /dev/null; then
        echo "dhcp" > "$BACKUP_DIR/mode_$timestamp.bak"
    else
        echo "static" > "$BACKUP_DIR/mode_$timestamp.bak"
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
    local selection
    selection=$(select_backup "$1") || exit 1

    local timestamp
    local base
    base=$(basename "$selection")
    timestamp=${base#mode_}
    timestamp=${timestamp%.bak}

    local mode_file="$selection"
    local ip_backup="$BACKUP_DIR/ip_addr_${timestamp}.bak"
    local route_backup="$BACKUP_DIR/ip_route_${timestamp}.bak"
    local resolv_backup="$BACKUP_DIR/resolv_${timestamp}.bak"

    local mode
    mode=$(cat "$mode_file")

    log "INFO" "使用备份时间戳 $timestamp, 模式: $mode"

    restore_network "$mode" "$ip_backup" "$route_backup" "$resolv_backup"
}

select_backup() {
    local preset="$1"
    mapfile -t backups < <(ls -t "$BACKUP_DIR"/mode_*.bak 2>/dev/null)

    if [ ${#backups[@]} -eq 0 ]; then
        log "ERROR" "未找到备份文件，无法回滚"
        return 1
    fi

    if [ -n "$preset" ]; then
        if ! [[ "$preset" =~ ^[0-9]+$ ]]; then
            log "ERROR" "无效的备份序号: $preset"
            return 1
        fi
        if [ "$preset" -lt 1 ] || [ "$preset" -gt ${#backups[@]} ]; then
            log "ERROR" "备份序号超出范围: $preset"
            return 1
        fi
        echo "${backups[$((preset - 1))]}"
        return 0
    fi

    echo "可用备份列表 (最新在前):" >&2
    local idx=1
    for f in "${backups[@]}"; do
        local ts
        ts=${f##*_}
        ts=${ts%.bak}
        echo "  [$idx] $ts ($f)" >&2
        idx=$((idx + 1))
    done

    read -p "请选择要回滚的序号: " choice
    if [ -z "$choice" ]; then
        choice=1
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#backups[@]} ]; then
        log "ERROR" "无效的备份序号"
        return 1
    fi

    echo "${backups[$((choice - 1))]}"
}

restore_network() {
    local mode="$1"
    local ip_backup="$2"
    local route_backup="$3"
    local resolv_backup="$4"

    pkill dhclient 2>/dev/null
    sleep 1
    ip addr flush dev "$ETH_DEV"
    ip route flush dev "$ETH_DEV"

    local ip_cidr
    if [ -f "$ip_backup" ]; then
        ip_cidr=$(awk -v dev="$ETH_DEV" '
            /^[0-9]+: / {iface=$2; sub(":", "", iface)}
            iface==dev && /inet / {print $2; exit}
        ' "$ip_backup")
        if [ -z "$ip_cidr" ]; then
            ip_cidr=$(awk '/inet / {print $2; exit}' "$ip_backup")
            [ -n "$ip_cidr" ] && log "INFO" "IP 未匹配网卡 $ETH_DEV，使用备份中的首个 IPv4: $ip_cidr"
        fi
    else
        log "WARNING" "未找到 IP 备份文件，跳过 IP 恢复"
    fi

    if [ -n "$ip_cidr" ]; then
        ip addr add "$ip_cidr" dev "$ETH_DEV"
        ip link set "$ETH_DEV" up
    else
        log "WARNING" "未在备份中找到 IP，跳过 IP 恢复"
    fi
    
    if [ -z "$ip_cidr" ]; then
        if [ "$mode" = "dhcp" ]; then
            log "INFO" "备份无 IP，按 dhcp 模式兜底续租"
            dhclient "$ETH_DEV"
        else
            log "INFO" "备份无 IP，按静态配置兜底"
            ip addr add "$STATIC_IP/$NETMASK" dev "$ETH_DEV" 2>/dev/null || true
            ip link set "$ETH_DEV" up
            ip route del default 2>/dev/null
            ip route add default via "$GATEWAY" dev "$ETH_DEV" 2>/dev/null || true
            [ -L "$RESOLV_FILE" ] && rm -f "$RESOLV_FILE"
            echo -e "nameserver $DNS1\nnameserver $DNS2" > "$RESOLV_FILE"
        fi
    fi

    if [ -f "$route_backup" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            if echo "$line" | grep -q '^default '; then
                ip route add $line 2>/dev/null
            fi
        done < "$route_backup"

        while IFS= read -r line; do
            [ -z "$line" ] && continue
            if echo "$line" | grep -q '^default '; then
                continue
            fi
            ip route add $line 2>/dev/null
        done < "$route_backup"
    else
        log "WARNING" "未找到路由备份，跳过路由恢复"
    fi

    if [ -f "$resolv_backup" ]; then
        [ -L "$RESOLV_FILE" ] && rm -f "$RESOLV_FILE"
        cp "$resolv_backup" "$RESOLV_FILE"
    else
        log "WARNING" "未找到 DNS 备份，跳过 DNS 恢复"
    fi

    if [ "$mode" == "dhcp" ]; then
        dhclient "$ETH_DEV"
    fi

    ip addr show "$ETH_DEV" >> "$LOG_FILE"
    ip route show >> "$LOG_FILE"

    log "INFO" "回滚完成"
}

usage() {
    cat << EOF
用法: ./network.sh [选项]

选项:
    dhcp      - 配置为办公网络模式(DHCP自动获取)
    static    - 配置为生产网络模式(静态IP)
    rollback  - 回滚到指定备份(可选序号参数)

示例:
    ./network.sh dhcp
    ./network.sh static
    ./network.sh rollback [序号]
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
            rollback "$2"
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
