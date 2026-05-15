#!/usr/bin/env bash
# stop.sh —— 停止所有服务，PID 文件优先，精确匹配回退

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib.sh"

echo -e "${BLUE}=== 股票分析服务关闭 ===${NC}"
echo ""

# 1. Cloudflare 临时隧道
stop_tunnel
echo -e "  ${GREEN}✓ ${TUNNEL_NAME} 已关闭${NC}"
echo ""

# 2. Web UI
stop_web
echo -e "  ${GREEN}✓ ${WEB_NAME} 已关闭${NC}"
echo ""

# 3. LLM Gateway
stop_gateway
echo -e "  ${GREEN}✓ ${GATEWAY_NAME} 已关闭${NC}"
echo ""

echo -e "${GREEN}=== 服务已关闭 ===${NC}"
