#!/bin/bash
# ============================================================
# onekey-tailscale_oci — PVE 一键重建 OCI Tailscale CT（CT102）
# 适用环境: PVE 9.1+（OCI 支持），宿主 root 运行
# 功能: 拉 OCI 镜像 → 建特权 CT → 状态持久化/tun 直通/环境变量 → hookscript IP 转发
# ============================================================
set -e

# ---------- 彩色输出 ----------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ---------- 检测 root ----------
if [ "$(id -u)" -ne 0 ]; then
  err "请以 root 用户运行 (当前非 root)"
fi

# ---------- 检测 PVE 环境 ----------
command -v pct &>/dev/null || err "未找到 pct，请确认在 PVE 宿主上运行"
command -v pveam &>/dev/null || err "未找到 pveam"
command -v skopeo &>/dev/null || err "未找到 skopeo（PVE 9.1+ OCI 支持依赖）"

# ---------- 配置 ----------
CTID=102
CT_NAME="Tailscale-Cliet"
CT_IP="192.168.50.3/24"
CT_GW="192.168.50.1"
TPL_REF="docker://tailscale/tailscale:latest"
TPL_NAME="tailscale_latest.tar"
VZTPL_DIR="/var/lib/vz/template/cache"
ROOTFS="local:0.5"
DATA_DIR="/opt/tailscale"

# ---------- 检测 local 存储模板目录 ----------
if [ ! -d "${VZTPL_DIR}" ]; then
  VZTPL_DIR=$(pveam list local 2>/dev/null | awk 'NR==2{print $2}' | sed 's|local:vztmpl/.*||')
  [ -n "${VZTPL_DIR}" ] || err "无法定位 vztmpl 目录，请检查 local 存储配置"
  VZTPL_DIR="${VZTPL_DIR}/vztmpl"
fi

# =================== ① 拉镜像 ===================
info "=== 1/5 拉取 OCI 镜像 ==="
# 重建目的为获取最新版本：模板存在则删除后重新拉取
if [ -f "${VZTPL_DIR}/${TPL_NAME}" ]; then
  info "  删除旧模板 ${TPL_NAME}（重建=拉取最新）"
  pveam remove "local:vztmpl/${TPL_NAME}"
fi
info "  拉取 ${TPL_REF} → ${VZTPL_DIR}/${TPL_NAME}"
skopeo copy "${TPL_REF}" "oci-archive:${VZTPL_DIR}/${TPL_NAME}"
info "  ✓ 模板拉取完成"

# =================== ② 建 CT ===================
info "=== 2/5 创建容器 ==="

# 选择容器 ID
read -p "请输入容器 ID (默认 102): " CTID_INPUT </dev/tty
CTID=${CTID_INPUT:-102}
CONF="/etc/pve/lxc/${CTID}.conf"
info "  容器 ID: ${CTID}"

# 输入 root 密码（不回显）
read -s -p "请输入容器 root 密码: " CT_PASS </dev/tty
echo ""
[ -n "${CT_PASS}" ] || err "密码不能为空"
info "  ✓ root 密码已设置（不回显）"

# 容器 IP / 网关（默认 192.168.50.3/24、192.168.50.1）
read -p "请输入容器 IP (默认 ${CT_IP}): " CT_IP_INPUT </dev/tty
CT_IP=${CT_IP_INPUT:-${CT_IP}}
read -p "请输入网关 IP (默认 ${CT_GW}): " CT_GW_INPUT </dev/tty
CT_GW=${CT_GW_INPUT:-${CT_GW}}
info "  容器 IP: ${CT_IP}（网关 ${CT_GW}）"

if pct status ${CTID} &>/dev/null; then
  warn "CT ${CTID} (${CT_NAME}) 已存在！"
  read -p "确认销毁并重建？(y/n，默认 n): " REBUILD </dev/tty
  if [ "${REBUILD:-n}" != "y" ] && [ "${REBUILD:-n}" != "Y" ]; then
    err "已取消，请手动处理 CT ${CTID}"
  fi
  pct stop ${CTID} 2>/dev/null || true
  pct destroy ${CTID} --purge
  info "  ✓ 旧 CT ${CTID} 已销毁"
fi

pct create ${CTID} "local:vztmpl/${TPL_NAME}" \
  --hostname "${CT_NAME}" --password "${CT_PASS}" \
  --rootfs "${ROOTFS}" --cores 1 --memory 512 --swap 0 \
  --net0 name=eth0,bridge=lan0,ip=${CT_IP},gw=${CT_GW},firewall=0 \
  --unprivileged 1 --features keyctl=1,nesting=1 \
  --cmode shell --start 0
info "  ✓ CT ${CTID} 已创建"

# =================== ③ 配置 ===================
info "=== 3/5 配置容器 ==="

# 删除 unprivileged: 1（新建完成后转特权——PVE 9.x OCI 特权创建是已知 bug，
# 必须先以 unprivileged 建成，再删除该行转为特权容器）
sed -i '/^unprivileged: 1$/d' "${CONF}"
info "  ✓ 已删除 unprivileged: 1（转为特权容器）"

# 控制台模式 shell（OCI 创建流程未写入，需显式设置）
pct set ${CTID} --cmode shell
info "  ✓ 控制台模式已设为 shell"

# 数据目录：不存在才新建，存在即绕过（保留状态）
if [ -d "${DATA_DIR}" ]; then
  info "  ${DATA_DIR} 已存在，保留（tailscale 状态持久化目录）"
else
  mkdir -p "${DATA_DIR}"
  info "  已创建 ${DATA_DIR}"
fi

# mp0 状态持久化挂载
pct set ${CTID} --mp0 "${DATA_DIR},mp=/var/lib/tailscale"
info "  ✓ mp0 挂载: ${DATA_DIR} → /var/lib/tailscale"

# tun 设备直通（幂等追加）
grep -q 'lxc.cgroup2.devices.allow: c 10:200' "${CONF}" || \
  echo 'lxc.cgroup2.devices.allow: c 10:200 rwm' >> "${CONF}"
grep -q 'lxc.mount.entry: /dev/net/tun' "${CONF}" || \
  echo 'lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file' >> "${CONF}"

# 环境变量（幂等追加）
for kv in "TS_STATE_DIR=/var/lib/tailscale" "TS_AUTH_ONCE=true" "TS_USERSPACE=false" "TS_EXTRA_ARGS=--exit-node="; do
  key="${kv%%=*}"
  grep -q "lxc.environment: ${key}=" "${CONF}" || echo "lxc.environment: ${kv}" >> "${CONF}"
done
info "  ✓ tun 直通 + 环境变量已写入 ${CONF}"

# =================== ④ hookscript ===================
info "=== 4/5 配置 hookscript（容器内 IP 转发） ==="

cat > "${DATA_DIR}/tailscale-sysctl.sh" << EOF
#!/bin/bash
echo "\$(date) hookscript called: phase=\$2" >> ${DATA_DIR}/hook.log
case "\$2" in
post-start)
# 等容器真正就绪（最多 30 秒），post-start 阶段容器可能还没起来
for i in \$(seq 1 30); do
  pct exec ${CTID} -- true 2>/dev/null && break
  sleep 1
done
pct exec ${CTID} -- sysctl -w net.ipv4.ip_forward=1 >> ${DATA_DIR}/hook.log 2>&1
pct exec ${CTID} -- sysctl -w net.ipv6.conf.all.forwarding=1 >> ${DATA_DIR}/hook.log 2>&1
pct exec ${CTID} -- sysctl -w net.ipv6.conf.default.forwarding=1 >> ${DATA_DIR}/hook.log 2>&1
;;
esac
EOF
chmod +x "${DATA_DIR}/tailscale-sysctl.sh"

mkdir -p /var/lib/vz/snippets
ln -sf "${DATA_DIR}/tailscale-sysctl.sh" /var/lib/vz/snippets/tailscale-sysctl.sh
pct set ${CTID} --hookscript local:snippets/tailscale-sysctl.sh
info "  ✓ hookscript 已挂载 (local:snippets/tailscale-sysctl.sh)"

# =================== ⑤ 启动 + 验证 ===================
info "=== 5/5 启动并验证 ==="

pct start ${CTID}
info "  ✓ CT ${CTID} 已启动"

# 等容器就绪
for i in $(seq 1 30); do
  pct exec ${CTID} -- true 2>/dev/null && break
  sleep 1
done

FORWARD=$(pct exec ${CTID} -- sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "?")
info "  容器内 ip_forward = ${FORWARD}"

if pct exec ${CTID} -- ps aux 2>/dev/null | grep -q tailscaled; then
  info "  ✓ tailscaled 已在容器内运行"
else
  warn "  ⚠ tailscaled 未自动启动——若 TS_* 环境变量未生效，可能需要 --entrypoint 指向 containerboot"
fi

# =================== 完成 ===================
echo ""
info "========== 配置信息汇总 =========="
info "  CT ID        : ${CTID}"
info "  容器名称     : ${CT_NAME}"
info "  容器 IP      : ${CT_IP}（网关 ${CT_GW}）"
info "  数据目录     : ${DATA_DIR} → /var/lib/tailscale"
info "  hookscript   : local:snippets/tailscale-sysctl.sh"
echo ""
info "=== 下一步：登录并启动 tailscale ==="
info "  pct exec ${CTID} -- tailscale up"
info "  首次运行会打印登录链接，浏览器打开授权即可"
echo ""
warn "请在本设备网关指向的路由设置静态转发，RouterOS 参考示例："
warn "  /ip/route/add dst-address=100.64.0.0/10 gateway=192.168.50.3"
warn "  /ip/route/add dst-address=192.168.58.0/24 gateway=192.168.50.3"
warn "  /ip/route/add dst-address=192.168.66.0/24 gateway=192.168.50.3"
