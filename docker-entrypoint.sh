#!/bin/sh
set -e

echo "=========================================="
echo "启动 Mihomo + Metacubexd 集成容器"
echo "=========================================="
echo "Mihomo 版本:      ${MI_VERSION}"
echo "Metacubexd 版本:  ${METACUBEXD_VERSION}"
echo "日志级别:         ${LOG_LEVEL:-info}"
echo "Web 端口:         ${CONTROL_PORT:-80}"
echo "订阅名称:         ${SUBSCRIBE_NAME:-未设置}"
echo "=========================================="

# 配置路径
CONFIG_DIR="/root/.config/mihomo"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
TEMPLATE_FILE="/app/config.yaml.template"

# 1. 生成 Mihomo 配置文件
mkdir -p "${CONFIG_DIR}"
if [ ! -f "${CONFIG_FILE}" ]; then
    echo "生成 Mihomo 配置文件..."
    if [ -f "${TEMPLATE_FILE}" ]; then
        envsubst '${LOG_LEVEL} ${CLASH_SECRET} ${SUBSCRIBE_NAME} ${SUBSCRIBE_URL}' < "${TEMPLATE_FILE}" > "${CONFIG_FILE}"
        echo "✅ 配置文件已生成: ${CONFIG_FILE}"
    else
        echo "❌ 错误: 未找到配置模板"
        exit 1
    fi
else
    echo "📁 使用现有配置文件: ${CONFIG_FILE}"
fi

# 2. 验证配置
echo "验证 Mihomo 配置..."
if mihomo -d "${CONFIG_DIR}" -t 2>/dev/null; then
    echo "✅ Mihomo 配置文件验证通过"
else
    echo "⚠️  Mihomo 配置文件验证失败，但继续启动..."
fi

# 3. 检测 mihomo API 端口（从 config.yaml 动态获取）
echo "检测 mihomo API 端口..."
API_PORT=""
if grep -q "^external-controller:" "${CONFIG_FILE}" 2>/dev/null; then
    # 从 config.yaml 中提取端口号（支持 '0.0.0.0:9090' / ':9090' / '127.0.0.1:9090' 等格式）
    API_PORT=$(grep "^external-controller:" "${CONFIG_FILE}" | sed "s/.*:\([0-9]*\).*/\1/" | head -1)
fi

if [ -z "${API_PORT}" ] || ! echo "${API_PORT}" | grep -qE '^[0-9]+$'; then
    # 不存在或无法解析，添加默认配置
    API_PORT=9090
    echo "external-controller: '0.0.0.0:${API_PORT}'" >> "${CONFIG_FILE}"
    echo "⚠️  config.yaml 中未找到 external-controller，已添加默认配置（端口 ${API_PORT}）"
else
    echo "✅ 从 config.yaml 读取到 API 端口: ${API_PORT}"
fi
export API_PORT

# 4. 生成 Caddyfile（动态端口）
CADDYFILE="/srv/Caddyfile"
CADDYFILE_TEMPLATE="/app/Caddyfile.template"
echo "生成 Caddyfile..."
if [ -f "${CADDYFILE_TEMPLATE}" ]; then
    envsubst '$CONTROL_PORT $API_PORT' < "${CADDYFILE_TEMPLATE}" > "${CADDYFILE}"
    caddy fmt --overwrite "${CADDYFILE}" 2>/dev/null || true
    echo "✅ Caddyfile 已生成，Web 端口: ${CONTROL_PORT:-80}，API 代理端口: ${API_PORT}"
else
    echo "❌ 错误: 未找到 Caddyfile 模板"
    exit 1
fi

# 5. 检测 API Secret（从 config.yaml 动态获取）
echo "检测 API Secret..."
API_SECRET=""
if grep -q "^secret:" "${CONFIG_FILE}" 2>/dev/null; then
    # 提取 secret 值（支持 secret: 'xxx' / secret: "xxx" / secret: xxx 格式）
    API_SECRET=$(grep "^secret:" "${CONFIG_FILE}" | sed "s/^secret:[[:space:]]*['\"]*//;s/['\"].*$//" | head -1)
fi
if [ -n "${API_SECRET}" ]; then
    echo "✅ 检测到 API Secret（已隐藏: ${API_SECRET:0:2}***）"
else
    echo "ℹ️  未配置 API Secret，面板无需密码即可连接"
fi

# 6. 生成 Metacubexd config.js（后台地址 + 自动认证）
CONFIG_JS_FILE="/srv/config.js"
echo "生成 Metacubexd config.js..."
if [ -n "${API_SECRET}" ]; then
    # 有密码：通过 URL 参数自动传入 hostname + secret，实现零配置连接
    cat > "${CONFIG_JS_FILE}" << 'CONFIGJS_HEAD'
window.__METACUBEXD_CONFIG__ = {
  defaultBackendURL: '',
  githubToken: '',
}
if (!window.location.hash || window.location.hash === '#/') {
  var params = new URLSearchParams({
    hostname: window.location.hostname,
    secret: 'CONFIGJS_SECRET'
  })
  window.location.replace('/#/?' + params.toString())
}
CONFIGJS_HEAD
    sed -i "s|CONFIGJS_SECRET|${API_SECRET}|g" "${CONFIG_JS_FILE}"
    echo "✅ config.js 已生成（自动连接 + 自动认证）"
else
    # 无密码：直接设置后台地址为当前 origin
    cat > "${CONFIG_JS_FILE}" << 'EOF'
window.__METACUBEXD_CONFIG__ = {
  defaultBackendURL: window.location.origin,
  githubToken: '',
}
EOF
    echo "✅ config.js 已生成（自动连接，无需密码）"
fi

# 7. 启动 Caddy Web 服务器
echo "启动 Caddy Web 服务器..."
caddy run --config /srv/Caddyfile --adapter caddyfile &

# 等待 Caddy 启动
sleep 2

# 8. 在前台启动 Mihomo
echo "启动 Mihomo 核心..."
exec mihomo -d "${CONFIG_DIR}"