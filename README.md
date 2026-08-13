# Tailscale OCI CT 一键重建脚本（PVE）

在 PVE 9.1+ 宿主机上一键重建 OCI Tailscale 容器（CT）：拉取最新镜像 → 创建容器 → 状态持久化 / tun 直通 / 环境变量 → hookscript IP 转发 → 启动验证。

## 快速开始

```bash
# 上传脚本到 PVE 宿主（root）
scp onekey-tailscale_oci.sh root@<PVE-IP>:/root/
# 运行
bash onekey-tailscale_oci.sh
```

## 脚本流程

| 步骤 | 说明 |
|---|---|
| ① 拉取 OCI 镜像 | 删除旧模板 → `skopeo copy` 拉取 `tailscale/tailscale:latest`（重建 = 取最新版本） |
| ② 创建容器 | 交互选择容器 ID（默认 102），已存在则确认销毁重建；以 unprivileged 创建 |
| ③ 配置容器 | 删除 `unprivileged: 1` 转特权、`cmode: shell`、状态持久化挂载 `/opt/tailscale → /var/lib/tailscale`、tun 直通、`TS_*` 环境变量 |
| ④ 配置 hookscript | 写入 `/opt/tailscale/tailscale-sysctl.sh` → 软链 snippets → 挂载（post-start 设置 ip_forward） |
| ⑤ 启动验证 | 启动容器，验证 `ip_forward=1` 与 tailscaled 进程 |

## 参数说明（脚本顶部变量，按需修改）

| 变量 | 默认值 | 说明 |
|---|---|---|
| `CTID` | 102（运行时交互可改） | 容器 ID |
| `CT_NAME` | Tailscale-Cliet | 容器名称 |
| `CT_PASS` | 运行时交互输入（不回显） | 容器 root 密码 |
| `CT_IP` | 见脚本 | 容器 IPv4（CIDR） |
| `CT_GW` | 见脚本 | 默认网关 |
| `TPL_REF` | `docker://tailscale/tailscale:latest` | OCI 镜像（skopeo 源，需 `docker://` 前缀） |
| `ROOTFS` | `local:0.5` | 根磁盘 |
| `DATA_DIR` | `/opt/tailscale` | 状态持久化目录（宿主机） |

## 注意事项

1. **PVE 9.x OCI 特权创建已知 bug**：`--unprivileged 0` 创建必失败（`setgid(0): Invalid argument`，官方确认）。脚本先以 unprivileged 创建成功，再删除 conf 中的 `unprivileged: 1` 转为特权容器。
2. **`TS_EXTRA_ARGS=--exit-node=` 必须保留（空值）**：防止 tailscale exit node 状态失控（否则 CT 访问局域网会被 ACL 拒绝）。
3. **`/opt/tailscale` 存在即保留**：tailscale 登录状态持久化，重建容器不丢失身份。
4. **重建后需在网关注册静态路由**（RouterOS 参考，`<CT-IP>` 替换为容器 IP）：
   ```
   /ip/route/add dst-address=100.64.0.0/10 gateway=<CT-IP>
   /ip/route/add dst-address=192.168.58.0/24 gateway=<CT-IP>
   /ip/route/add dst-address=192.168.66.0/24 gateway=<CT-IP>
   ```
5. 容器启动后登录：`pct exec <CTID> -- tailscale up`，首次会打印授权链接。

## 验证

```bash
pct exec <CTID> -- sysctl -n net.ipv4.ip_forward   # 应输出 1
pct exec <CTID> -- ps aux | grep tailscaled        # 应存在进程
pct exec <CTID> -- tailscale status                # tailnet 状态
```
