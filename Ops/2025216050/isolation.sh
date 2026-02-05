#!/bin/bash

# 网络设备
ETH_DEV="eth0"

# 内网网段
LOCAL_NETWORK="172.22.146.0/24"
INTERNAL_NETWORK="172.16.0.0/12"

# 文件路径
LOG_FILE="/var/log/isolation.log"
BACKUP_DIR="/var/backup/iptables"

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

backup_rules() {
    mkdir -p "$BACKUP_DIR"
    local timestamp=$(date +"%Y%m%d_%H%M%S")

    iptables-save > "$BACKUP_DIR/iptables_$timestamp.bak"

    log "INFO" "已备份当前 iptables 规则到 $BACKUP_DIR/iptables_$timestamp.bak"
}

enable_isolation() {
    log "INFO" "启用生产网络隔离..."
    
    backup_rules
    iptables -F OUTPUT
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -d "$LOCAL_NETWORK" -j ACCEPT
    iptables -A OUTPUT -d "$INTERNAL_NETWORK" -j ACCEPT
    iptables -A OUTPUT -j LOG --log-prefix "[ISOLATION BLOCKED] " --log-level 4
    iptables -A OUTPUT -j DROP
    
    log "INFO" "生产网络隔离已启用"
    log "INFO" "允许访问: $LOCAL_NETWORK, $INTERNAL_NETWORK"
    log "INFO" "禁止访问公网地址"
}

disable_isolation() {
    log "INFO" "禁用生产网络隔离..."
    
    iptables -F OUTPUT
    iptables -P OUTPUT ACCEPT
    
    log "INFO" "生产网络隔离已禁用"
}

rollback_rules() {
    mapfile -t backups < <(ls -t "$BACKUP_DIR"/iptables_*.bak 2>/dev/null)

    if [ ${#backups[@]} -eq 0 ]; then
        log "ERROR" "未找到备份文件"
        return 1
    fi

    local choice
    local preset="$1"

    if [ -n "$preset" ]; then
        if ! [[ "$preset" =~ ^[0-9]+$ ]] || [ "$preset" -lt 1 ] || [ "$preset" -gt ${#backups[@]} ]; then
            log "ERROR" "无效的备份序号: $preset"
            return 1
        fi
        choice=$preset
    else
        echo "可用备份列表 (最新在前):" >&2
        local idx=1
        for f in "${backups[@]}"; do
            echo "  [$idx] $f" >&2
            idx=$((idx + 1))
        done

        read -p "请选择要回滚的序号: " choice
        [ -z "$choice" ] && choice=1
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#backups[@]} ]; then
            log "ERROR" "无效的备份序号"
            return 1
        fi
    fi

    local target="${backups[$((choice - 1))]}"
    log "INFO" "回滚到: $target"
    iptables-restore < "$target"
    log "INFO" "规则已回滚"
}

usage() {
    cat << EOF
用法: ./isolation.sh [选项]

选项:
    enable    启用生产网络隔离
    disable   禁用生产网络隔离
    rollback  回滚到指定备份(可选序号参数)

示例:
    ./isolation.sh enable
    ./isolation.sh disable
    ./isolation.sh rollback [序号]
EOF
}

main() {
    check_root
    
    case "$1" in
        enable)
            enable_isolation
            ;;
        disable)
            disable_isolation
            ;;
        rollback)
            rollback_rules "$2"
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"