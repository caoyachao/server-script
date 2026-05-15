#!/usr/bin/env bash
# start.sh —— 启动所有服务，带环境预检、PID 管理、事务回滚

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib.sh"

# 捕获 Ctrl-C 和 ERR，触发回滚
cleanup_on_exit() {
    if (( ${#STARTED_SERVICES[@]} > 0 )); then
        rollback
    fi
}
trap cleanup_on_exit EXIT INT TERM

echo -e "${BLUE}=== 股票分析服务启动 ===${NC}"
echo ""

# ── 环境预检 ──
if ! check_environment; then
    echo ""
    echo -e "${RED}✗ 环境检查未通过，启动中止${NC}"
    exit 1
fi
echo ""

# ── 清理残留 PID 文件 ──
validate_pid_file "$GATEWAY_PID" || true
validate_pid_file "$WEB_PID" || true
validate_pid_file "$TUNNEL_PID" || true

# ── 启动 Gateway ──
if is_port_in_use "$GATEWAY_PORT"; then
    # 检查是否是我们自己的服务
    local_port_pid=$(get_port_pid_checked "$GATEWAY_PORT" "$GATEWAY_PROC_HINT" || true)
    if [[ -n "${local_port_pid:-}" ]]; then
        echo -e "${YELLOW}⚠ ${GATEWAY_NAME} 已在端口 ${GATEWAY_PORT} 运行（PID: ${local_port_pid}），跳过启动${NC}"
        write_pid "$GATEWAY_PID" "$local_port_pid"
    else
        echo -e "${RED}✗ 端口 ${GATEWAY_PORT} 被未知进程占用，启动中止${NC}"
        exit 1
    fi
else
    echo -e "${BLUE}▶ 启动 ${GATEWAY_NAME}（端口 ${GATEWAY_PORT}）...${NC}"
    log_file=$(prepare_log "gateway")

    cd "$LLM_GATEWAY_DIR"
    nohup bash -c 'source .venv/bin/activate && exec python -m llm_gateway_sdk.server --port '"${GATEWAY_PORT}"'' > "$log_file" 2>&1 &
    pid=$!
    write_pid "$GATEWAY_PID" "$pid"
    record_started "gateway"
    cd "$SCRIPT_DIR"

    if wait_for_service "$GATEWAY_HEALTH" "$GATEWAY_NAME" "$MAX_WAIT_GATEWAY"; then
        echo -e "  ${GREEN}PID: ${pid}${NC}"
        echo -e "  ${GREEN}日志: ${GATEWAY_LOG} -> $(basename "$log_file")${NC}"
    else
        echo -e "${RED}✗ ${GATEWAY_NAME} 启动失败，查看日志: ${log_file}${NC}"
        exit 1
    fi
fi

echo ""

# ── 启动 Web UI ──
if is_port_in_use "$WEB_PORT"; then
    local_port_pid=$(get_port_pid_checked "$WEB_PORT" "$WEB_PROC_HINT" || true)
    if [[ -n "${local_port_pid:-}" ]]; then
        echo -e "${YELLOW}⚠ ${WEB_NAME} 已在端口 ${WEB_PORT} 运行（PID: ${local_port_pid}），跳过启动${NC}"
        write_pid "$WEB_PID" "$local_port_pid"
    else
        echo -e "${RED}✗ 端口 ${WEB_PORT} 被未知进程占用，启动中止${NC}"
        exit 1
    fi
else
    echo -e "${BLUE}▶ 启动 ${WEB_NAME}（端口 ${WEB_PORT}）...${NC}"
    log_file=$(prepare_log "web")

    cd "$COMPANY_RESEARCH_DIR"
    export PORT="$WEB_PORT"
    export LLM_GATEWAY_URL="http://127.0.0.1:${GATEWAY_PORT}/v1"
    nohup node ./node_modules/tsx/dist/cli.mjs src/web/server.ts > "$log_file" 2>&1 &
    pid=$!
    write_pid "$WEB_PID" "$pid"
    record_started "web"
    cd "$SCRIPT_DIR"

    if wait_for_service "$WEB_HEALTH" "$WEB_NAME" "$MAX_WAIT_WEB"; then
        echo -e "  ${GREEN}PID: ${pid}${NC}"
        echo -e "  ${GREEN}日志: ${WEB_LOG} -> $(basename "$log_file")${NC}"
    else
        echo -e "${RED}✗ ${WEB_NAME} 启动失败，查看日志: ${log_file}${NC}"
        exit 1
    fi
fi

echo ""

# ── 启动 Cloudflare Tunnel ──
if is_process_running "$TUNNEL_PATTERN"; then
    echo -e "${YELLOW}⚠ ${TUNNEL_NAME} 已运行，跳过启动${NC}"
else
    echo -e "${BLUE}▶ 启动 ${TUNNEL_NAME}（目标 http://localhost:${WEB_PORT}）...${NC}"

    # 清理旧隧道，等待完全消失
    pkill -f "$TUNNEL_PATTERN" 2>/dev/null || true
    wait_until_gone "$TUNNEL_PATTERN" "$TUNNEL_NAME"

    log_file=$(prepare_log "tunnel")

    rm -f "$log_file"
    nohup cloudflared tunnel --url "http://localhost:${WEB_PORT}" > "$log_file" 2>&1 &
    pid=$!
    write_pid "$TUNNEL_PID" "$pid"
    record_started "tunnel"

    # 等待域名生成
    tunnel_url=""
    for i in $(seq 1 $MAX_WAIT_TUNNEL); do
        tunnel_url=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$log_file" | head -1 || true)
        if [[ -n "$tunnel_url" ]]; then
            echo -e "${GREEN}✓ ${TUNNEL_NAME} 已启动${NC}"
            echo -e "  ${GREEN}PID: ${pid}${NC}"
            echo -e "  ${GREEN}日志: ${TUNNEL_LOG} -> $(basename "$log_file")${NC}"
            echo -e ""
            echo -e "  ${BLUE}Tunnel URL:${NC} ${tunnel_url}"
            echo -e "  ${BLUE}Pages 访问链接：${NC}"
            echo -e "    <你的Pages_URL>/#api=${tunnel_url}"
            echo -e "    例如: https://your-project.pages.dev/#api=${tunnel_url}"
            echo -e "  ${BLUE}本地 API 测试：${NC}"
            echo -e "    curl \"${tunnel_url}/api/stock-data?stock=600519.SH\""
            break
        fi
        sleep 2
    done

    if [[ -z "${tunnel_url:-}" ]]; then
        echo -e "${YELLOW}⚠ ${TUNNEL_NAME} 域名尚未生成，请稍后查看日志: ${log_file}${NC}"
        echo -e "  ${GREEN}PID: ${pid}${NC}"
    fi
fi

echo ""
echo -e "${GREEN}=== 服务启动完成 ===${NC}"
echo ""
echo -e "  ${GREEN}${GATEWAY_NAME}${NC}     http://localhost:${GATEWAY_PORT}"
echo -e "  ${GREEN}${WEB_NAME}${NC} http://localhost:${WEB_PORT}"
echo -e "  ${GREEN}CLI 分析${NC}        cd ${COMPANY_RESEARCH_DIR} && npx tsx src/main.ts <股票代码>"
echo ""
echo -e "${BLUE}使用 ./stop.sh 关闭服务，./status.sh 查看状态${NC}"

# 成功启动后清除回滚陷阱
trap - EXIT INT TERM
