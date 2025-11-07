#!/usr/bin/env bash
# fws.sh - 完整交互式管理脚本 (Debian/Ubuntu)
# 功能：安装/卸载/管理 ttyd, gost, frps(with token+frpc sample), 3x-ui, EasyTier, OneTimeMessagePHP
#       为已安装服务创建 Nginx 反向代理并绑定子域（用于 Cloudflare）
# 使用：sudo ./fws.sh
set -euo pipefail
IFS=$'\n\t'

### ====== 配置区（可根据需要修改） ======
WORK_DIR="/opt/fws"
FRP_CFG_DIR="/etc/frp"
ONETIME_DIR="/var/www/onetimemessagephp"
NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
USE_UFW="yes"             # yes/no
DEFAULT_TTYD_PORT=7681
DEFAULT_FRPS_PORT=7000
DEFAULT_FRPS_DASHBOARD=7500
# End config
### ========================================

# colors
C_R="\e[31m" C_G="\e[32m" C_Y="\e[33m" C_B="\e[34m" C_RV="\e[7m" C_X="\e[0m"
echo_color(){ printf "${C_G}%s${C_X}\n" "$*"; }
echo_warn(){ printf "${C_Y}%s${C_X}\n" "$*"; }
echo_err(){ printf "${C_R}%s${C_X}\n" "$*"; }
echo_info(){ printf "${C_B}%s${C_X}\n" "$*"; }

# prepare
sudo mkdir -p "$WORK_DIR" "$FRP_CFG_DIR" "$NGINX_SITES_AVAILABLE" "$NGINX_SITES_ENABLED"

require_apt() {
  if ! command -v apt-get >/dev/null 2>&1; then
    echo_err "本脚本仅支持 Debian/Ubuntu（需 apt-get）"
    exit 1
  fi
}

ensure_base() {
  echo_color "更新 apt 并安装基础依赖..."
  sudo apt-get update -y
  sudo apt-get install -y curl wget git ca-certificates apt-transport-https software-properties-common unzip tar xz-utils lsb-release gnupg || true
}

open_port() {
  local port=$1 proto=${2:-tcp}
  if [ "$USE_UFW" = "yes" ] && command -v ufw >/dev/null 2>&1; then
    sudo ufw allow "$port"/"$proto" || true
  fi
}

# nginx reverse proxy creation (supports websocket headers)
create_nginx_proxy() {
  local svc="$1" subdomain="$2" tgt="$3" tport="$4"
  local conf="${NGINX_SITES_AVAILABLE}/${svc}.${subdomain}.conf"
  cat <<EOF | sudo tee "$conf" >/dev/null
server {
    listen 80;
    server_name ${subdomain};

    client_max_body_size 100M;

    location / {
        proxy_pass http://${tgt}:${tport};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
  sudo ln -sf "$conf" "${NGINX_SITES_ENABLED}/$(basename "$conf")"
  if sudo nginx -t >/dev/null 2>&1; then
    sudo systemctl reload nginx || true
    echo_color "Nginx 已创建反代：${subdomain} -> ${tgt}:${tport}"
    echo_color "请在 Cloudflare 添加子域 ${subdomain} 的 A 记录指向本 VPS 公网 IP（代理可选：Proxied 或 DNS only，若使用 Cloudflare 的 CDN/Proxy，选择 Proxied）"
  else
    echo_warn "nginx 配置测试失败，请检查 ${conf}"
  fi
}

# systemd unit helper
create_systemd_unit() {
  local path="$1" content="$2"
  echo "$content" | sudo tee "$path" >/dev/null
  sudo systemctl daemon-reload
}

###############################
# ttyd
###############################
install_ttyd() {
  echo_color "安装 ttyd..."
  ensure_base
  sudo apt-get install -y build-essential cmake libjson-c-dev libwebsockets-dev || true
  cd "$WORK_DIR"
  if [ -d "$WORK_DIR/ttyd" ]; then
    cd "$WORK_DIR/ttyd" && git pull || true
  else
    git clone https://github.com/tsl0922/ttyd.git "$WORK_DIR/ttyd"
    cd "$WORK_DIR/ttyd"
  fi
  mkdir -p build && cd build
  cmake .. || true
  make -j"$(nproc)" || true
  sudo make install || true

  local svc="/etc/systemd/system/ttyd.service"
  cat <<EOF | sudo tee "$svc" >/dev/null
[Unit]
Description=ttyd - Share terminal over the web
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ttyd -p ${DEFAULT_TTYD_PORT} -t disableReconnect=true bash
Restart=on-failure
User=root
Environment=TERM=xterm-256color

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now ttyd.service || true
  open_port "${DEFAULT_TTYD_PORT}"
  echo_color "ttyd 已安装并启动（端口 ${DEFAULT_TTYD_PORT}）"
  read -rp "是否为 ttyd 绑定域名并创建 nginx 反代? (y/N): " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    read -rp "请输入子域名 (例如 ttyd.example.com): " sd
    create_nginx_proxy "ttyd" "$sd" "127.0.0.1" "${DEFAULT_TTYD_PORT}"
  fi
}

uninstall_ttyd() {
  echo_color "卸载 ttyd..."
  sudo systemctl disable --now ttyd.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/ttyd.service
  sudo rm -f /usr/local/bin/ttyd || true
  sudo rm -rf "$WORK_DIR/ttyd" || true
  sudo systemctl daemon-reload
  echo_color "ttyd 已卸载"
}

manage_ttyd() {
  echo "ttyd 管理: 1-start 2-stop 3-restart 4-status 5-enable 6-disable"
  read -rp "选择: " op
  case "$op" in
    1) sudo systemctl start ttyd.service ;;
    2) sudo systemctl stop ttyd.service ;;
    3) sudo systemctl restart ttyd.service ;;
    4) sudo systemctl status ttyd.service --no-pager || true ;;
    5) sudo systemctl enable ttyd.service ;;
    6) sudo systemctl disable ttyd.service ;;
    *) echo_warn "取消" ;;
  esac
}

###############################
# gost
###############################
install_gost() {
  echo_color "安装 gost..."
  ensure_base
  bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --install || true
  # create systemd if not exists
  if ! systemctl list-unit-files | grep -q "^gost.service"; then
    local svc="/etc/systemd/system/gost.service"
    cat <<EOF | sudo tee "$svc" >/dev/null
[Unit]
Description=gost proxy
After=network.target

[Service]
Type=simple
ExecStart=$(command -v gost || echo /usr/local/bin/gost) -L=:1080
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
  fi
  sudo systemctl enable --now gost.service || true
  open_port 1080
  echo_color "gost 安装/启动完成 (默认端口:1080)"
  read -rp "是否为 gost 绑定域名并创建 nginx 反代? (y/N): " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    read -rp "请输入子域名 (例如 gost.example.com): " sd
    create_nginx_proxy "gost" "$sd" "127.0.0.1" "1080"
  fi
}

uninstall_gost() {
  echo_color "卸载 gost..."
  sudo systemctl disable --now gost.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/gost.service || true
  [ -f /usr/local/bin/gost ] && sudo rm -f /usr/local/bin/gost || true
  sudo systemctl daemon-reload
  echo_color "gost 已卸载"
}

manage_gost() {
  echo "gost 管理: 1-start 2-stop 3-restart 4-status 5-enable 6-disable"
  read -rp "选择: " op
  case "$op" in
    1) sudo systemctl start gost.service ;;
    2) sudo systemctl stop gost.service ;;
    3) sudo systemctl restart gost.service ;;
    4) sudo systemctl status gost.service --no-pager || true ;;
    5) sudo systemctl enable gost.service ;;
    6) sudo systemctl disable gost.service ;;
    *) echo_warn "取消" ;;
  esac
}

###############################
# frps (server) + frpc sample
###############################
install_frps() {
  echo_color "安装 frps (server) 并生成 token + frpc 示例..."
  ensure_base
  sudo apt-get install -y curl tar || true
  cd "$WORK_DIR"
  local rel tarball tmpd frps_path frpc_path
  rel=$(curl -sL "https://api.github.com/repos/fatedier/frp/releases/latest" || true)
  tarball=$(echo "$rel" | grep "browser_download_url" | grep linux_amd64 | head -n1 | awk -F '"' '{print $4}' || true)
  if [ -n "$tarball" ]; then
    echo_color "下载 frp 发布包..."
    tmpd=$(mktemp -d)
    cd "$tmpd"
    curl -LJ "$tarball" -o frp.tar.gz || true
    tar zxvf frp.tar.gz || true
    frps_path=$(find . -type f -name frps | head -n1 || true)
    frpc_path=$(find . -type f -name frpc | head -n1 || true)
    [ -n "$frps_path" ] && sudo cp "$frps_path" /usr/local/bin/frps || true
    [ -n "$frpc_path" ] && sudo cp "$frpc_path" /usr/local/bin/frpc || true
    sudo chmod +x /usr/local/bin/frps /usr/local/bin/frpc || true
    rm -rf "$tmpd" || true
  else
    echo_warn "未从 GitHub Releases 获取到 frp 二进制，尝试源码构建..."
    cd "$WORK_DIR"
    git clone https://github.com/fatedier/frp frp-src || true
    cd frp-src || true
    make frps || true
    [ -f ./bin/frps ] && sudo cp ./bin/frps /usr/local/bin/frps || true
  fi

  local frp_token
  frp_token=$(head -c 32 /dev/urandom | xxd -ps | cut -c1-32)
  sudo mkdir -p "$FRP_CFG_DIR"
  cat <<EOF | sudo tee "${FRP_CFG_DIR}/frps.ini" >/dev/null
[common]
bind_port = ${DEFAULT_FRPS_PORT}
dashboard_port = ${DEFAULT_FRPS_DASHBOARD}
dashboard_user = admin
dashboard_pwd = admin
token = ${frp_token}
vhost_http_port = 8080
EOF

  cat <<'EOF' | sudo tee /etc/systemd/system/frps.service >/dev/null
[Unit]
Description=frps server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c /etc/frp/frps.ini
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user-target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now frps.service || true
  open_port "${DEFAULT_FRPS_PORT}"
  open_port "${DEFAULT_FRPS_DASHBOARD}"
  open_port 8080

  cat <<EOF | sudo tee "${FRP_CFG_DIR}/frpc.sample.ini" >/dev/null
[common]
server_addr = YOUR_FRPS_PUBLIC_IP_OR_DOMAIN
server_port = ${DEFAULT_FRPS_PORT}
token = ${frp_token}

[ssh]
type = tcp
local_ip = 127.0.0.1
local_port = 22
remote_port = 6000

# http vhost 示例：
# [web]
# type = http
# local_port = 80
# custom_domains = yoursub.example.com
EOF

  echo_color "frps 安装完成，配置: ${FRP_CFG_DIR}/frps.ini"
  echo_color "frpc 示例: ${FRP_CFG_DIR}/frpc.sample.ini（将 server_addr 替换为公网 IP/域名）"
  read -rp "是否为 frps dashboard 绑定域名并创建 nginx 反代? (y/N): " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    read -rp "请输入子域名 (例如 frps.example.com): " sd
    create_nginx_proxy "frps-dashboard" "$sd" "127.0.0.1" "${DEFAULT_FRPS_DASHBOARD}"
  fi
}

uninstall_frps() {
  echo_color "卸载 frps..."
  sudo systemctl disable --now frps.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/frps.service || true
  sudo rm -f /usr/local/bin/frps /usr/local/bin/frpc || true
  sudo rm -rf "$FRP_CFG_DIR" || true
  sudo systemctl daemon-reload
  echo_color "frps 已卸载"
}

manage_frps() {
  echo "frps 管理:1-start 2-stop 3-restart 4-status 5-enable 6-disable"
  read -rp "选择: " op
  case "$op" in
    1) sudo systemctl start frps.service ;;
    2) sudo systemctl stop frps.service ;;
    3) sudo systemctl restart frps.service ;;
    4) sudo systemctl status frps.service --no-pager || true ;;
    5) sudo systemctl enable frps.service ;;
    6) sudo systemctl disable frps.service ;;
    *) echo_warn "取消" ;;
  esac
}

###############################
# 3x-ui
###############################
install_3xui() {
  echo_color "安装 3x-ui..."
  ensure_base
  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) || true
  echo_color "3x-ui 安装尝试完成"
  read -rp "是否为 3x-ui 绑定域名并创建 nginx 反代? (y/N): " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    read -rp "请输入子域名 (例如 xui.example.com): " sd
    # 默认 3x-ui 的 web 端口通常为 8888/你的安装配置，请根据实际更改
    read -rp "请输入 3x-ui 的本地端口 (默认 8888): " p; p=${p:-8888}
    create_nginx_proxy "3xui" "$sd" "127.0.0.1" "$p"
  fi
}

###############################
# EasyTier
###############################
install_easytier() {
  echo_color "安装 EasyTier..."
  ensure_base
  wget -O- https://raw.githubusercontent.com/EasyTier/EasyTier/main/script/install.sh | sudo bash -s install || true
  echo_color "EasyTier 安装尝试完成"
  read -rp "是否为 EasyTier 绑定域名并创建 nginx 反代? (y/N): " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    read -rp "请输入子域名 (例如 easytier.example.com): " sd
    read -rp "请输入 EasyTier 的本地端口 (例如 8080): " p
    create_nginx_proxy "easytier" "$sd" "127.0.0.1" "$p"
  fi
}

###############################
# hy2 & argosbx
###############################
install_hy2() {
  echo_color "安装 hy2..."
  ensure_base
  bash <(curl -fsSL https://get.hy2.sh/) || true
  echo_color "hy2 安装尝试完成"
}

install_argosbx() {
  echo_color "安装 argosbx (甬哥脚本)..."
  ensure_base
  bash <(curl -Ls https://raw.githubusercontent.com/yonggekkk/argosbx/main/argosbx.sh) || true
  echo_color "argosbx 安装尝试完成"
}

###############################
# OneTimeMessagePHP (阅后即焚)
###############################
install_onetimemsg() {
  echo_color "安装 OneTimeMessagePHP..."
  ensure_base
  sudo apt-get install -y nginx php-fpm php-mbstring php-xml php-curl unzip || true
  sudo mkdir -p "$ONETIME_DIR"
  if [ -d "${ONETIME_DIR}/.git" ]; then
    cd "$ONETIME_DIR" && sudo git pull || true
  else
    sudo git clone https://github.com/frankiejun/OneTimeMessagePHP.git "$ONETIME_DIR" || true
  fi
  echo_color "OneTimeMessagePHP 已下载至 ${ONETIME_DIR}"
  read -rp "是否为 OneTimeMessagePHP 绑定域名并创建 nginx 反代? (y/N): " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    read -rp "请输入子域名 (例如 note.example.com): " sd
    read -rp "请输入 OneTimeMessagePHP 的本地端口 (默认 80): " p; p=${p:-80}
    create_nginx_proxy "onetimemsg" "$sd" "127.0.0.1" "$p"
  fi
}

uninstall_onetimemsg() {
  echo_color "卸载 OneTimeMessagePHP ..."
  sudo rm -rf "$ONETIME_DIR" || true
  sudo rm -f "${NGINX_SITES_AVAILABLE}/onetimemsg."* || true
  sudo rm -f "${NGINX_SITES_ENABLED}/onetimemsg."* || true
  sudo systemctl reload nginx || true
  echo_color "OneTimeMessagePHP 已移除"
}

###############################
# UFW helper
###############################
setup_ufw() {
  echo_color "设置 UFW 并开放 22/80/443 以及已知服务端口..."
  sudo apt-get install -y ufw || true
  sudo ufw allow OpenSSH || true
  sudo ufw allow 80/tcp || true
  sudo ufw allow 443/tcp || true
  sudo ufw --force enable || true
  # open common ports used above
  open_port "${DEFAULT_TTYD_PORT}"
  open_port "${DEFAULT_FRPS_PORT}"
  open_port "${DEFAULT_FRPS_DASHBOARD}"
  open_port 1080
  open_port 8888
  open_port 8080
  echo_color "UFW 配置完成"
}

###############################
# 自检 / 状态汇总
###############################
self_check() {
  echo_color "=== 自检开始 ==="
  echo "系统："
  uname -a
  echo
  echo "已安装二进制（可用项）："
  for b in /usr/local/bin/ttyd /usr/local/bin/frps /usr/local/bin/frpc /usr/local/bin/gost /usr/bin/gost; do
    [ -x "$b" ] && echo " - $b"
  done
  echo
  echo "systemd 服务状态（ttyd/frps/gost/nginx）:"
  for s in ttyd frps gost nginx; do
    if systemctl list-units --full -all | grep -q "^ *${s}"; then
      sudo systemctl status "$s" --no-pager || true
    else
      echo " - $s : 未注册或不存在"
    fi
  done
  echo
  if [ -f "${FRP_CFG_DIR}/frps.ini" ]; then
    echo_color "frps 配置片段 (/etc/frp/frps.ini):"
    sudo sed -n '1,120p' "${FRP_CFG_DIR}/frps.ini" || true
  else
    echo_warn "/etc/frp/frps.ini 不存在"
  fi
  echo_color "=== 自检完成 ==="
}

###############################
# 菜单交互
###############################
main_menu() {
  require_apt
  # ensure nginx installed for proxy tasks
  if ! command -v nginx >/dev/null 2>&1; then
    echo_color "安装 nginx..."
    sudo apt-get update -y
    sudo apt-get install -y nginx || true
    sudo systemctl enable --now nginx || true
  fi

  while true; do
    echo
    echo -e "${C_RV}======== FWS 管理脚本 ========${C_X}"
    echo "1) 安装组件 (选择)"
    echo "2) 卸载组件 (选择)"
    echo "3) 管理组件 (start/stop/restart/status/enable/disable)"
    echo "4) 为服务创建 Nginx 反代并可选申请证书"
    echo "5) 安装 frps (server) 并生成 frpc 示例（含 token）"
    echo "6) UFW & 端口管理"
    echo "7) 自检/状态汇总"
    echo "0) 退出"
    read -rp "请选择: " op
    case "$op" in
      1) choose_install_menu ;;
      2) choose_uninstall_menu ;;
      3) choose_manage_menu ;;
      4) create_proxy_interactive ;;
      5) install_frps ;;
      6) setup_ufw ;;
      7) self_check ;;
      0) echo_color "退出"; exit 0 ;;
      *) echo_warn "无效选项" ;;
    esac
  done
}

choose_install_menu() {
  echo
  echo "选择安装组件:"
  echo "a) ttyd"
  echo "b) gost"
  echo "c) frps (server)"
  echo "d) 3x-ui"
  echo "e) EasyTier"
  echo "f) hy2"
  echo "g) argosbx (甬哥)"
  echo "h) OneTimeMessagePHP (阅后即焚)"
  echo "i) 全部安装（顺序）"
  read -rp "选择 (a-i): " c
  case "$c" in
    a) install_ttyd ;;
    b) install_gost ;;
    c) install_frps ;;
    d) install_3xui ;;
    e) install_easytier ;;
    f) install_hy2 ;;
    g) install_argosbx ;;
    h) install_onetimemsg ;;
    i) install_all ;;
    *) echo_warn "取消或无效" ;;
  esac
}

choose_uninstall_menu() {
  echo
  echo "选择卸载组件:"
  echo "a) ttyd"
  echo "b) gost"
  echo "c) frps"
  echo "d) OneTimeMessagePHP"
  echo "e) 其它（手动）"
  read -rp "选择 (a-e): " c
  case "$c" in
    a) uninstall_ttyd ;;
    b) uninstall_gost ;;
    c) uninstall_frps ;;
    d) uninstall_onetimemsg ;;
    e) echo_warn "请参考组件 README 手动卸载" ;;
    *) echo_warn "取消或无效" ;;
  esac
}

choose_manage_menu() {
  echo
  echo "管理组件 (输入 systemd 服务名，例如 ttyd/frps/gost/nginx):"
  read -rp "服务名: " svc
  [ -z "$svc" ] && { echo_warn "未输入"; return; }
  echo "动作: 1-start 2-stop 3-restart 4-status 5-enable 6-disable"
  read -rp "选择: " act
  case "$act" in
    1) sudo systemctl start "$svc" ;;
    2) sudo systemctl stop "$svc" ;;
    3) sudo systemctl restart "$svc" ;;
    4) sudo systemctl status "$svc" --no-pager || true ;;
    5) sudo systemctl enable "$svc" ;;
    6) sudo systemctl disable "$svc" ;;
    *) echo_warn "取消或无效" ;;
  esac
}

create_proxy_interactive() {
  read -rp "服务标识(用于文件名, 例如 ttyd/onetime/frps-dashboard): " svc
  read -rp "请输入要绑定的子域 (例如 ttyd.fws.x10.mx): " subd
  read -rp "目标主机 (默认 127.0.0.1): " tgt; tgt=${tgt:-127.0.0.1}
  read -rp "目标端口 (例如 7681): " tport
  create_nginx_proxy "$svc" "$subd" "$tgt" "$tport"
  read -rp "是否现在尝试申请 Let's Encrypt 证书并启用 HTTPS? (y/N): " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    sudo apt-get install -y certbot python3-certbot-nginx || true
    sudo certbot --nginx -d "$subd" || echo_warn "certbot 可能失败，请手动运行：sudo certbot --nginx -d $subd"
  fi
}

install_all() {
  ensure_base
  install_ttyd
  install_gost
  install_frps
  install_3xui
  install_easytier
  install_hy2
  install_argosbx
  install_onetimemsg
  echo_color "全部安装尝试完成"
}

# Entrypoint
if [ "$EUID" -ne 0 ]; then
  echo_warn "建议以 root 运行以避免频繁 sudo（脚本在必要处会使用 sudo）"
fi

echo_color "欢迎使用 FWS 管理脚本"
main_menu
