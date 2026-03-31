

# 🚀 Caddy + AliDNS 企业级一键离线部署包

[![GitHub release (latest by date)](https://img.shields.io/github/v/release/%E4%BD%A0%E7%9A%84%E7%94%A8%E6%88%B7%E5%90%8D/%E4%BD%A0%E7%9A%84%E4%BB%93%E5%BA%93%E5%90%8D)](https://github.com/你的用户名/你的仓库名/releases)[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

本项目是基于官方 [Caddy](https://caddyserver.com/) 定制的多架构静态编译版本，内置了 `caddy-dns/alidns` 插件。并附带了一个**仿 Nginx 目录结构**的企业级一键离线安装脚本 (`.run` 格式)。

彻底解决国内服务器使用 Caddy 申请通配符/泛域名 HTTPS 证书的痛点，开箱即用，无需安装 Go 环境，无需公网暴露 80 端口（DNS-01 验证）。

------

## ✨ 核心特性

- 🇨🇳 **阿里云 DNS 集成**：通过 DNS-01Challenge 自动申请和续期 Let's Encrypt 证书，支持泛域名。
- 📦 **纯离线部署**：打包为 `.run` 自解压格式，复制到内网服务器即可安装，无任何外部依赖。
- 🏗️ **企业级架构**：摒弃 Caddy 默认的单文件配置，仿照 Nginx 划分 `snippets` (中间件层)、`sites-available` (业务层)、`sites-enabled` (启停层)，极其适合多站点管理。
- 🔒 **安全防护内置**：自动注入 HSTS、X-Frame-Options 等安全响应头，屏蔽后端指纹泄露。
- 🔌 **标准代理透传**：自动携带 `X-Forwarded-For`、`X-Real-IP` 等标准头，完美适配 Spring Boot / Go / Node.js 后端获取真实 IP。
- 🌊 **流式传输优化**：内置针对 WebSocket 和 SSE (如 ChatGPT 流式输出) 的超时优化，永不断连。
- 📊 **Prometheus 监控**：原生开启 Metrics 端点，无需额外编译插件，直接对接 Grafana 监控面板。
- 🐧 **多架构支持**：提供 `amd64` (x86_64) 和 `arm64` (鲲鹏/苹果云) 离线包。

------

## 📁 部署后的目录架构 (类似 Nginx)

安装完成后，Caddy 的配置不再是一个杂乱的文件，而是结构清晰的企业级目录树：

```text
/etc/caddy/
├── Caddyfile                   # 【全局层】主入口，仅包含阿里云AK/SK和全局日志格式
├── snippets/                   # 【中间件层】可复用的配置片段
│   ├── security-headers.conf   #   └─ 安全响应头 (HSTS, XSS防御等)
│   └── proxy-headers.conf      #   └─ 反向代理标准透传头 (真实IP透传)
├── sites-available/            # 【业务层】各个域名的具体配置文件
│   └── api.example.com.conf    #   └─ 某个业务的完整配置 (路由、代理、静态文件)
└── sites-enabled/              # 【控制层】软链接目录 (控制哪些站点生效)
    └── api.example.com.conf -> ../sites-available/api.example.com.conf
```



------

## 📥 下载与安装

前往 [Releases](https://github.com/你的用户名/你的仓库名/releases) 页面下载对应架构的 `.run` 文件。

### 方式一：命令行静默安装 (推荐)

为了避免 AK/SK 泄露到 Shell 历史记录中，建议先创建一个配置文件 `deploy.conf`：

ini



AK=LTAI5txxxxxxxxxxxxxxxxxx

SK=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

DOMAIN=api.example.com

BACKEND=127.0.0.1:8080

REGION=cn-hangzhou

\# FRONTEND=/var/www/html/dist  # 如果是前后端分离，取消注释并填写前端目录



执行安装：

bash



chmod +x caddy-alidns-linux-amd64.run

sudo ./caddy-alidns-linux-amd64.run --config deploy.conf



也可以直接传参（不推荐，会留下命令记录）：

bash



sudo ./caddy-alidns-linux-amd64.run --ak "YOUR_AK" --sk "YOUR_SK" --domain "api.example.com" --backend "127.0.0.1:8080"



### 方式二：交互式向导安装

直接运行安装包，根据中文提示一步步输入：

bash



sudo ./caddy-alidns-linux-amd64.run



------

## 🎯 支持的部署模式

### 模式 A：纯后端反向代理 (微服务/API 服务)

不携带 `--frontend` 参数时触发。访问 `https://域名` 直接透传给后端。 *适用场景：Spring Boot 后端、Golang API、Grafana 等纯接口服务。*

### 模式 B：前后端分离托管 (Vue/React + API)

携带 `--frontend /path/to/dist` 参数时触发。

- **前端**：访问 `https://域名/` 或 `https://域名/xxx` 返回静态文件，并自动处理 Vue/React 的 History 路由 (`try_files`)，支持自动压缩 (`br/gzip`)。
- **后端**：访问 `https://域名/api/*` 自动转发给 `--backend` 指定的服务。 *适用场景：企业官网、后台管理系统、前后端分离项目。*

------

## 🛠️ 企业级运维指南

### 1. 查看监控指标

本版本已默认开启 Prometheus 指标采集，在服务器本地执行：

bash



curl http://localhost:2019/metrics



你可以配置 Prometheus 抓取该端点，导入 Caddy 官方 Dashboard 查看 QPS、带宽、连接数。

### 2. 新增一个站点 (不影响现有站点)

1. 在 `sites-available` 下新建配置：

   bash

   

   sudo vim /etc/caddy/sites-available/blog.example.com.conf

   写入如下内容（复用中间件）：

   caddy

   

   blog.example.com {

   ​    tls {

   ​        dns alidns {

   ​            propagation_timeout 5m

   ​            resolvers 223.5.5.5

   ​        }

   ​    }

   ​    import snippets/security-headers.conf

   ​    

   ​    root * /var/www/blog

   ​    try_files {path} /index.html

   ​    file_server

   }

2. 创建软链接启用站点：

   bash

   

   sudo ln -s /etc/caddy/sites-available/blog.example.com.conf /etc/caddy/sites-enabled/

3. 平滑重载配置 (**不中断现有连接**)：

   bash

   

   sudo systemctl reload caddy

### 3. 临时下线某个站点 (无需删除代码)

直接删除软链接并重载即可：

bash



sudo rm /etc/caddy/sites-enabled/blog.example.com.conf

sudo systemctl reload caddy



### 4. 查看日志

Caddy 默认输出 JSON 格式日志到 systemd：

bash



\# 查看实时日志

journalctl -u caddy -f

\# 查看最近的错误日志

journalctl -u caddy -p err -n 50



### 5. 验证配置语法

在修改配置后，重载前可以先验证语法是否正确：

bash



/usr/local/bin/caddy validate --config /etc/caddy/Caddyfile



------

## ⚠️ 常见问题排查

**1. 提示 `Resource not accessible by integration` 或证书申请失败？**

- 检查阿里云 AccessKey 是否赋予了 `AliyunDNSFullAccess` 权限。
- 检查域名是否确实在配置的 AK 对应的阿里云账号下。
- 检查服务器是否能连通公网（需要向 Let's Encrypt 发起 HTTP 请求验证权限，虽然不需要开 80 端口）。

**2. 提示 `80/443 端口被占用`？** 安装脚本检测到 Nginx 或其他服务占用了端口。请先停用旧服务：

bash



systemctl stop nginx

systemctl disable nginx

\# 然后重新运行 .run 安装包



**3. 后端 Java/Go 程序获取不到客户端真实 IP，全都是 127.0.0.1？** 本脚本已默认注入 `proxy-headers.conf`。如果你的后端还获取不到，请检查你的后端框架（如 Spring Boot Nginx 解析配置）是否配置了信任代理层级（如 `server.toml.max-http-header-size` 或 Nginx 配置的 `X-Real-IP` 解析）。Caddy 传递的 Header 是绝对标准的。

**4. 部署后前端页面刷新 404？** 这是因为 Vue/React 的 History 模式路由。本脚本的 `try_files {path} /index.html` 已经处理了该问题。如果出现 404，请检查你运行 `.run` 时是否正确填写了 `--frontend` 参数。

------

## 🔨 本地编译 (供开发者参考)

如果你需要自己编译不同版本的 Caddy，请参考本仓库的 `.github/workflows/build.yml`。

核心编译命令：

bash



\# 安装 xcaddy

go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

\# 交叉编译 (例如 Linux AMD64)

GOOS=linux GOARCH=amd64 CGO_ENABLED=0 xcaddy build v2.11.2 --with github.com/caddy-dns/alidns



------

## 📄 开源协议

基于 Caddy 和 AliDNS 插件的原有协议。本部署脚本采用 [MIT](https://opensource.org/licenses/MIT) 协议开源。