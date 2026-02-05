#!/bin/bash

# 公网测试地址
PUBLIC_IP="8.8.8.8"
PUBLIC_IP_BACKUP="114.114.114.114"

# 网络设备
ETH_DEV="eth0"

# 文件路径
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="$(readlink -f "$0")"
NETWORK_SCRIPT="$SCRIPT_DIR/network.sh"
LOG_FILE="/var/log/network_check.log"

# 定时任务内容
CRON_JOB="* * * * * $SCRIPT_PATH check"

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

check_public_access() {
    if ping -c 1 -W 2 -I "$ETH_DEV" "$PUBLIC_IP" &>/dev/null; then
        return 0
    fi
    
    if ping -c 1 -W 2 -I "$ETH_DEV" "$PUBLIC_IP_BACKUP" &>/dev/null; then
        return 0
    fi
    
    return 1
}

enable_cron() {
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH"; then
        log "INFO" "定时任务已经启用"
        return 0
    fi
    
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    
    if [ $? -eq 0 ]; then
        log "INFO" "定时任务已启用（每分钟）"
    else
        log "ERROR" "启用失败"
        return 1
    fi
}

disable_cron() {
    if ! crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH"; then
        log "INFO" "定时任务未启用"
        return 0
    fi
    
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -
    
    if [ $? -eq 0 ]; then
        log "INFO" "定时任务已禁用"
    else
        log "ERROR" "禁用失败"
        return 1
    fi
}

do_check() {
    if check_public_access; then
        if [ ! -x "$NETWORK_SCRIPT" ]; then
            log "ERROR" "找不到 network.sh: $NETWORK_SCRIPT"
            return 1
        fi
        log "WARNING" "检测到公网可达，切换办公网络模式 (DHCP)"
        "$NETWORK_SCRIPT" dhcp
    else
        log "INFO" "定时检测隔离正常"
    fi
}

usage() {
    cat << EOF
用法: ./check_network.sh [选项]

选项:
    enable   启用定时检测（每分钟）
    disable  禁用定时检测
    check    立即执行一次检测

示例:
    ./check_network.sh enable
    ./check_network.sh disable
    ./check_network.sh check
EOF
}

main() {
    check_root
    
    case "$1" in
        enable)
            enable_cron
            ;;
        disable)
            disable_cron
            ;;
        check)
            do_check
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"