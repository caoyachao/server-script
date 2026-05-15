#!/usr/bin/env bash
# status.sh —— 查询各服务状态：进程 / 端口 / 日志

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib.sh"

check_service_status() {
    local name=$1
    local pid_file=$2
    local health_url=$3
    local log_file=$4
    local proc_hint=$5

    local pid=""
    local pid_status="未运行"
    local port_status="未监听"
    local health_status="未知"
    local log_errors="无"

    # PID 检查
    if [[ -f "$pid_file" ]]; then
        pid=$(cat "$pid_file" 2>/dev/null || true)
        if [[ -n "$pid" ]] && is_process_alive "$pid"; then
            pid_status="运行中 (PID: $pid)"
        else
            pid_status="僵尸 (PID 文件残留: $pid)"
        fi
    fi

    # 端口/健康检查
    if [[ -n "$health_url" ]]; then
        if curl -s --max-time 5 --connect-timeout 3 "$health_url" >/dev/null 2>&1; then
            health_status="健康"
            port_status="响应"
        else
            health_status="无响应"
            port_status="无响应"
        fi
    fi

    # 日志错误检查（最近 20 行）
    if [[ -f "$log_file" ]]; then
        local err_count
        err_count=$(tail -n 20 "$log_file" 2>/dev/null | grep -cE "ERROR|Exception|Traceback|Error" || true)
        if ((err_count > 0)); then
            log_errors="最近 20 行含 ${err_count} 处异常"
        fi
    fi

    # 颜色判断
    local overall="健康"
    local color="$GREEN"
    if [[ "$pid_status" == "未运行" ]]; then
        overall="未运行"
        color="$YELLOW"
    elif [[ "$health_status" == "无响应" ]]; then
        overall="僵尸/无响应"
        color="$RED"
    elif [[ "$log_errors" != "无" ]]; then
        overall="运行中(有报错)"
        color="$YELLOW"
    fi

    printf "  %-20s ${color}%-18s${NC}  %-10s  %-20s\n" "$name" "$overall" "$port_status" "$log_errors"
}

echo -e "${BLUE}=== 股票分析服务状态 ===${NC}"
echo ""
printf "  ${BOLD}%-20s %-18s %-10s %-20s${NC}\n" "服务" "整体状态" "端口" "日志异常"
printf "  %-20s %-18s %-10s %-20s\n" "--------------------" "------------------" "----------" "--------------------"

check_service_status "$GATEWAY_NAME" "$GATEWAY_PID" "$GATEWAY_HEALTH" "$GATEWAY_LOG" "$GATEWAY_PROC_HINT"
check_service_status "$WEB_NAME"     "$WEB_PID"     "$WEB_HEALTH"     "$WEB_LOG"     "$WEB_PROC_HINT"
check_service_status "$TUNNEL_NAME"  "$TUNNEL_PID"  ""               "$TUNNEL_LOG"  "$TUNNEL_PROC_HINT"

echo ""

# 显示日志软链接指向的实际文件
echo -e "${CYAN}日志文件位置：${NC}"
for link in "$GATEWAY_LOG" "$WEB_LOG" "$TUNNEL_LOG"; do
    if [[ -L "$link" ]]; then
        target=$(readlink -f "$link" 2>/dev/null || true)
        printf "  %-30s -> %s\n" "$(basename "$link")" "$(basename "$target")"
    fi
done

echo ""
echo -e "${BLUE}使用 ./start.sh 启动，./stop.sh 关闭，./restart.sh 重启${NC}"
