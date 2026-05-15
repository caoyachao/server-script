#!/usr/bin/env bash
# restart.sh —— 原子级重启：先停止全部服务，再顺序启动

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 给 PID 文件清理留出时间窗口，确保 stop 完成
stop_script="${SCRIPT_DIR}/stop.sh"
start_script="${SCRIPT_DIR}/start.sh"

echo -e "\033[0;34m=== 股票分析服务重启 ===\033[0m"
echo ""

if [[ -x "$stop_script" ]]; then
    "$stop_script"
else
    echo -e "\033[0;31m✗ 未找到 stop.sh\033[0m"
    exit 1
fi

echo ""
echo -e "\033[0;36m等待 PID 文件清理...\033[0m"
sleep 1

# 二次确认 PID 文件已清理
for pid_file in "${SCRIPT_DIR}/logs/gateway.pid" "${SCRIPT_DIR}/logs/web.pid" "${SCRIPT_DIR}/logs/tunnel.pid"; do
    if [[ -f "$pid_file" ]]; then
        rm -f "$pid_file"
    fi
done

if [[ -x "$start_script" ]]; then
    "$start_script"
else
    echo -e "\033[0;31m✗ 未找到 start.sh\033[0m"
    exit 1
fi
