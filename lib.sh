#!/usr/bin/env bash
# lib.sh —— 公共函数库，被所有运维脚本 source
# 依赖：先 source config.sh

set -euo pipefail

# ── 日志轮转 ──
# 生成 <name>-YYYYMMDD.log，若已存在且超过阈值则轮转为 .1 .2...
# 并创建/更新符号链接 <name>.log -> <name>-YYYYMMDD.log
prepare_log() {
    local name=$1
    local log_link="${LOG_DIR}/${name}.log"
    local date_suffix
    date_suffix=$(date +%Y%m%d)
    local log_file="${LOG_DIR}/${name}-${date_suffix}.log"

    # 如果当日文件已存在且超过 10MB，追加序号
    local max_size=$((10 * 1024 * 1024))
    if [[ -f "$log_file" ]]; then
        local size
        size=$(stat -c%s "$log_file" 2>/dev/null || echo 0)
        if (( size > max_size )); then
            local idx=1
            while [[ -f "${log_file}.${idx}" ]]; do
                ((idx++))
            done
            mv "$log_file" "${log_file}.${idx}"
        fi
    fi

    # 创建/更新软链接
    rm -f "$log_link"
    ln -s "$(basename "$log_file")" "$log_link"

    # 返回实际日志文件路径（用于 nohup 重定向）
    printf '%s' "$log_file"
}

# ── PID 管理 ──
write_pid() {
    local pid_file=$1
    local pid=$2
    printf '%s\n' "$pid" > "$pid_file"
}

read_pid() {
    local pid_file=$1
    if [[ -f "$pid_file" ]]; then
        cat "$pid_file"
    fi
}

clean_pid() {
    local pid_file=$1
    rm -f "$pid_file"
}

is_process_alive() {
    local pid=$1
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# 校验 PID 文件：若指向进程已死，自动清理
validate_pid_file() {
    local pid_file=$1
    local pid
    pid=$(read_pid "$pid_file")
    if [[ -n "$pid" ]] && ! is_process_alive "$pid"; then
        clean_pid "$pid_file"
        return 1
    fi
    return 0
}

# ── 端口与进程检测 ──
is_port_in_use() {
    local port=$1
    lsof -i :"$port" -sTCP:LISTEN >/dev/null 2>&1
}

# 获取占用端口的 PID，并验证进程名是否匹配预期
get_port_pid_checked() {
    local port=$1
    local expected_hint=$2
    local pids
    pids=$(lsof -t -i :"$port" -sTCP:LISTEN 2>/dev/null || true)
    if [[ -z "$pids" ]]; then
        return 1
    fi
    # 仅取第一个 PID
    local pid
    pid=$(echo "$pids" | head -n1)
    local comm
    comm=$(ps -p "$pid" -o comm= 2>/dev/null || true)
    if [[ "$comm" == "$expected_hint"* ]]; then
        printf '%s' "$pid"
        return 0
    fi
    return 1
}

is_process_running() {
    local pattern=$1
    pgrep -f "$pattern" >/dev/null 2>&1
}

# ── 精确关闭 ──
kill_by_pid() {
    local pid=$1
    local name=$2
    if ! is_process_alive "$pid"; then
        return 0
    fi
    kill -TERM "$pid" 2>/dev/null || true

    local waited=0
    while ((waited < KILL_WAIT_TIMEOUT)); do
        if ! is_process_alive "$pid"; then
            return 0
        fi
        sleep 1
        ((waited++)) || true
    done

    if is_process_alive "$pid"; then
        kill -KILL "$pid" 2>/dev/null || true
        sleep 1
    fi
}

kill_by_port_checked() {
    local port=$1
    local name=$2
    local expected_hint=$3
    local pids
    pids=$(lsof -t -i :"$port" -sTCP:LISTEN 2>/dev/null || true)
    if [[ -z "$pids" ]]; then
        return 0
    fi

    # 逐个检查进程名，只杀匹配的
    local killed_any=0
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        local comm
        comm=$(ps -p "$pid" -o comm= 2>/dev/null || true)
        if [[ "$comm" == "$expected_hint"* ]]; then
            echo -e "  ${BLUE}▶ 关闭 ${name}（端口 ${port}，PID: ${pid}）...${NC}"
            kill_by_pid "$pid" "$name"
            killed_any=1
        else
            echo -e "  ${YELLOW}⚠ 端口 ${port} 被未知进程占用（PID: ${pid}, comm: ${comm}），跳过${NC}"
        fi
    done <<< "$pids"
    return 0
}

kill_by_pattern() {
    local pattern=$1
    local name=$2
    local pids
    pids=$(pgrep -f "$pattern" 2>/dev/null || true)
    if [[ -z "$pids" ]]; then
        return 0
    fi

    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        echo -e "  ${BLUE}▶ 关闭 ${name}（PID: ${pid}）...${NC}"
        kill_by_pid "$pid" "$name"
    done <<< "$pids"
}

# ── 等待进程完全消失 ──
wait_until_gone() {
    local pattern=$1
    local name=$2
    local waited=0
    while is_process_running "$pattern"; do
        if ((waited >= TUNNEL_EXIT_TIMEOUT)); then
            # 强制清理
            local pids
            pids=$(pgrep -f "$pattern" 2>/dev/null || true)
            while IFS= read -r pid; do
                [[ -z "$pid" ]] && continue
                kill -KILL "$pid" 2>/dev/null || true
            done <<< "$pids"
            sleep 1
            break
        fi
        sleep 1
        ((waited++)) || true
    done
}

# ── 健康检查 ──
wait_for_service() {
    local url=$1
    local name=$2
    local max_wait=${3:-30}
    local waited=0

    while ! curl -s --max-time 2 "$url" >/dev/null 2>&1; do
        if ((waited >= max_wait)); then
            echo -e "${RED}✗ ${name} 启动超时（${max_wait}秒）${NC}"
            return 1
        fi
        sleep 1
        ((waited++)) || true
    done
    echo -e "${GREEN}✓ ${name} 已就绪${NC}"
    return 0
}

# ── 环境预检 ──
check_environment() {
    local ok=1
    if [[ ! -d "$LLM_GATEWAY_DIR/.venv" ]]; then
        echo -e "${RED}✗ 缺少 llm-gateway-sdk/.venv${NC}"
        ok=0
    fi
    if [[ ! -f "$LLM_GATEWAY_DIR/.venv/bin/activate" ]]; then
        echo -e "${RED}✗ .venv/bin/activate 不存在${NC}"
        ok=0
    fi
    if [[ ! -d "$COMPANY_RESEARCH_DIR/node_modules" ]]; then
        echo -e "${RED}✗ company-research/node_modules 缺失，请先 pnpm install${NC}"
        ok=0
    fi
    if ! command -v cloudflared >/dev/null 2>&1; then
        echo -e "${RED}✗ 未找到 cloudflared 命令${NC}"
        ok=0
    fi
    if ((ok == 0)); then
        return 1
    fi
    echo -e "${GREEN}✓ 环境检查通过${NC}"
    return 0
}

# ── 回滚 ──
# 全局数组，记录本次已启动的服务
STARTED_SERVICES=()

record_started() {
    local svc=$1
    STARTED_SERVICES+=("$svc")
}

rollback() {
    if (( ${#STARTED_SERVICES[@]} == 0 )); then
        return 0
    fi
    echo -e "${YELLOW}⚠ 启动失败，回滚已启动的服务...${NC}"
    # 倒序关闭
    for ((i = ${#STARTED_SERVICES[@]} - 1; i >= 0; i--)); do
        local svc=${STARTED_SERVICES[i]}
        case "$svc" in
            gateway)
                echo -e "  ${BLUE}▶ 回滚关闭 ${GATEWAY_NAME}${NC}"
                stop_gateway
                ;;
            web)
                echo -e "  ${BLUE}▶ 回滚关闭 ${WEB_NAME}${NC}"
                stop_web
                ;;
            tunnel)
                echo -e "  ${BLUE}▶ 回滚关闭 ${TUNNEL_NAME}${NC}"
                stop_tunnel
                ;;
        esac
    done
    STARTED_SERVICES=()
}

# ── 服务级停止函数（供 rollback / stop.sh 复用）─
stop_gateway() {
    local pid
    pid=$(read_pid "$GATEWAY_PID")
    if [[ -n "$pid" ]] && is_process_alive "$pid"; then
        kill_by_pid "$pid" "$GATEWAY_NAME"
        clean_pid "$GATEWAY_PID"
        return 0
    fi
    clean_pid "$GATEWAY_PID"
    kill_by_port_checked "$GATEWAY_PORT" "$GATEWAY_NAME" "$GATEWAY_PROC_HINT"
}

stop_web() {
    local pid
    pid=$(read_pid "$WEB_PID")
    if [[ -n "$pid" ]] && is_process_alive "$pid"; then
        kill_by_pid "$pid" "$WEB_NAME"
        clean_pid "$WEB_PID"
        return 0
    fi
    clean_pid "$WEB_PID"
    kill_by_port_checked "$WEB_PORT" "$WEB_NAME" "$WEB_PROC_HINT"
}

stop_tunnel() {
    local pid
    pid=$(read_pid "$TUNNEL_PID")
    if [[ -n "$pid" ]] && is_process_alive "$pid"; then
        kill_by_pid "$pid" "$TUNNEL_NAME"
        clean_pid "$TUNNEL_PID"
    fi
    clean_pid "$TUNNEL_PID"
    kill_by_pattern "$TUNNEL_PATTERN" "$TUNNEL_NAME"
    wait_until_gone "$TUNNEL_PATTERN" "$TUNNEL_NAME"
}
