#!/usr/bin/env bash
# config.sh —— 统一配置，被所有运维脚本 source

set -euo pipefail

# ── 路径 ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECTS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMPANY_RESEARCH_DIR="${PROJECTS_ROOT}/company-research"
LLM_GATEWAY_DIR="${PROJECTS_ROOT}/llm-gateway-sdk"

# ── 端口 ──
GATEWAY_PORT=${GATEWAY_PORT:-8000}
WEB_PORT=${WEB_PORT:-3000}

# ── 日志与 PID ──
LOG_DIR="${SCRIPT_DIR}/logs"
PID_DIR="${LOG_DIR}"
mkdir -p "$LOG_DIR"

# ── 超时配置（秒）─
MAX_WAIT_GATEWAY=30
MAX_WAIT_WEB=15
MAX_WAIT_TUNNEL=30
KILL_WAIT_TIMEOUT=5
TUNNEL_EXIT_TIMEOUT=10

# ── 颜色 ──
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── 服务定义 ──
# 格式: 名称|启动命令|进程名匹配|健康检查URL|日志文件|PID文件
GATEWAY_NAME="LLM Gateway"
GATEWAY_CMD="source .venv/bin/activate && exec python -m llm_gateway_sdk.server --port ${GATEWAY_PORT}"
GATEWAY_PATTERN="python -m llm_gateway_sdk.server"
GATEWAY_PROC_HINT="python"
GATEWAY_HEALTH="http://localhost:${GATEWAY_PORT}/health"
GATEWAY_LOG="${LOG_DIR}/gateway.log"
GATEWAY_PID="${PID_DIR}/gateway.pid"

WEB_NAME="股票分析 Web UI"
WEB_CMD="PORT=${WEB_PORT} LLM_GATEWAY_URL=http://127.0.0.1:${GATEWAY_PORT}/v1 node ./node_modules/tsx/dist/cli.mjs src/web/server.ts"
WEB_PATTERN="tsx/dist/cli.mjs src/web/server.ts"
WEB_PROC_HINT="node"
WEB_HEALTH="http://localhost:${WEB_PORT}"
WEB_LOG="${LOG_DIR}/web.log"
WEB_PID="${PID_DIR}/web.pid"

TUNNEL_NAME="Cloudflare 临时隧道"
TUNNEL_CMD="cloudflared tunnel --url http://localhost:${WEB_PORT}"
TUNNEL_PATTERN="cloudflared tunnel --url"
TUNNEL_PROC_HINT="cloudflared"
TUNNEL_HEALTH=""
TUNNEL_LOG="${LOG_DIR}/tunnel.log"
TUNNEL_PID="${PID_DIR}/tunnel.pid"
