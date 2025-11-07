# 🛠️ FWS.SH - 多功能 Linux 工具箱

FWS.SH 是一个集成多种常用服务的 Linux 自动化安装与管理脚本。  
支持一键安装、状态查看、启停管理、开机自启、Nginx 反向代理、Cloudflare 域名绑定等功能。

---

## 🚀 支持的功能模块

| 模块名称 | 功能说明 | 默认端口 |
|-----------|-----------|-----------|
| **TTYD** | Web 终端访问 | `7681` |
| **Gost** | 网络代理/转发服务 | `8081` |
| **EasyTier** | 局域网互联组网 | `51820` |
| **FRPS** | 内网穿透服务端 | `7000` / `7500` |
| **3x-UI** | XRay 多协议面板 | `2053` |
| **阅后即焚** | PHP 阅后即焚系统 | `8080` |
| **Nginx 域名反代** | 自动 HTTPS + 域名绑定 | `443` |

---

## 📋 系统要求

- 操作系统：Debian / Ubuntu / Deepin / Armbian / Kali / Ubuntu Server
- 需要 root 权限
- 推荐配置：
  - 内存 ≥ 512MB  
  - 硬盘 ≥ 2GB  
  - 稳定公网 IP 或 Cloudflare 域名  

---

## ⚙️ 一键安装


bash <(curl -fsSL https://github.com/flower-wins/fws/blob/main/fws.sh)
或手动下载运行：

bash
复制代码
```bash
wget -O fws.sh https://github.com/flower-wins/fws/blob/main/fws.sh && chmod +x fws.sh && ./fws.sh
```
🧭 使用菜单
运行后进入交互菜单：

```markdown

复制代码
==========================
     FWS 多功能工具箱
==========================
1. 安装/管理 TTYD
2. 安装/管理 Gost
3. 安装/管理 EasyTier
4. 安装/管理 FRPS
5. 安装/管理 3x-UI
6. 安装/管理 阅后即焚
7. 管理域名反向代理
8. 查看服务状态
9. 设置开机自启
0. 退出
==========================
请输入选项编号：
```
🌐 自动反代与 Cloudflare 域名绑定
FWS.SH 支持自动反代和证书生成。

🧩 反代逻辑说明
假设你在 Cloudflare 上有一个域名：

复制代码
x10.mx
脚本会根据服务创建子域名并反代：

服务	反代子域名	端口	示例
ttyd	ttyd.x10.mx	7681	https://ttyd.x10.mx
gost	gost.x10.mx	8081	https://gost.x10.mx
frps	frps.x10.mx	7500	https://frps.x10.mx
3x-ui	panel.x10.mx	2053	https://panel.x10.mx
阅后即焚	burn.x10.mx	8080	https://burn.x10.mx

🔐 SSL 证书自动签发
支持以下证书方案：

Cloudflare 反代 HTTPS（推荐）

ZeroSSL / Let’s Encrypt 自动签发

本地自签证书（测试用）

脚本会自动生成 /etc/nginx/sites-enabled/xxx.conf 配置并启用。

🧩 FRP 模块说明
FRPS 安装路径：/usr/local/frp/

Token 自动启用
脚本会随机生成强随机 token（例如 Frp_23fjQkzPsd8!）
并生成一个 frpc.ini 示例文件：

```ini
[common]
server_addr = your.vps.ip
server_port = 7000
token = Frp_23fjQkzPsd8!

[web]
type = tcp
local_ip = 127.0.0.1
local_port = 8080
remote_port = 8080
```
📁 文件路径结构
路径	说明
/root/fws.sh	主脚本
/usr/local/frp/	FRPS 配置目录
/etc/nginx/sites-enabled/	域名反代配置
/var/www/OneTimeMessagePHP/	阅后即焚系统
/usr/bin/ttyd	ttyd 可执行文件
/usr/local/bin/gost	gost 程序

🧰 服务管理命令
以下命令在菜单中自动调用，也可手动执行：

```bash
# 启动服务
systemctl start frps
systemctl start ttyd

# 查看状态
systemctl status gost

# 设置开机自启
systemctl enable 3x-ui
```
💡 常见问题
Q1: 域名没反代成功？
👉 确认域名已解析到服务器 IP，并关闭 Cloudflare 橙色云（DNS Only）模式。

Q2: 反代后 502？
👉 检查服务是否启动、端口是否放行、防火墙规则是否正确。

Q3: 想卸载？
👉 在菜单中选择对应模块，然后选“卸载”即可。

🧑‍💻 作者信息
脚本作者：FlowerWins

GitHub：https://github.com/flower-wins/fws

项目主页：

📜 许可证
本项目遵循 MIT License。
使用本脚本即表示你同意自行承担因使用脚本带来的任何风险。

💬 欢迎反馈与改进建议！

```bash
bash <(curl -fsSL https://github.com/flower-wins/fws/blob/main/fws.sh)
```
🌟 让 Linux 管理更轻松，让服务部署更简单。

yaml
复制代码

---

是否希望我为你生成配套的  
✅ `nginx反代模板文件`（自动根据域名+端口创建），  
和  
✅ `fws.conf`（用于保存域名、路径、模块状态）  
以便脚本运行时动态生成反代与状态显示？
