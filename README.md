# Caddy + AliDNS 离线安装工具

这套仓库现在只做两件事：

1. 通过 GitHub Actions 在线构建带 `dns.providers.alidns` 插件的 `amd64 / arm64` Caddy 二进制  
2. 把二进制打成可离线安装的 `.run` 包，自动完成 systemd、Caddyfile、站点模板和检测工具的落地

整体设计目标是“简单但能打”：

- 仓库里只保留 `build.sh / install.sh / README.md / .github/workflows/build.yml`
- 安装时由 `install.sh` 自动生成 `/etc/caddy` 目录结构、systemd、测试工具
- 适配新版 Caddy，避免旧配置里常见的过时语法
- 默认支持 AliDNS 自动签证和自动续期

## 目录和职责

- `build.sh`
  - 不编译 Caddy
  - 只负责把已经构建好的二进制打成离线 `.run`
- `install.sh`
  - 既可以作为 `.run` 安装器，也可以在仓库里直接配合同目录 `caddy` 二进制执行
  - 负责安装、幂等覆盖、systemd、站点初始化和测试工具
- `.github/workflows/build.yml`
  - GitHub Actions 在线构建 `amd64 / arm64`
  - 自动打出 `.run`
  - 打 tag 时自动发布 release

## 当前安装后的结构

安装完成后会生成下面这套结构：

```text
/etc/caddy/
├── Caddyfile
├── caddy.env
├── snippets/
│   ├── proxy-headers.caddy
│   └── security-headers.caddy
├── sites-available/
└── sites-enabled/
```

说明：

- `Caddyfile`
  - 只放全局项和 `import /etc/caddy/sites-enabled/*.caddy`
- `caddy.env`
  - 放 ACME 邮箱、AliDNS 凭据、admin 地址等
- `snippets`
  - 放公共片段，后面每个业务站点都复用
- `sites-available`
  - 每个域名一个文件
- `sites-enabled`
  - 软链接控制是否生效

这套结构就是为了让后续每个应用维护自己的文件，而不是把所有业务都塞进一个大配置里。

## 构建方式

### 方式一：本地打包现成二进制

如果你已经从 GitHub Actions 或其他地方拿到了 Caddy 二进制：

```bash
chmod +x build.sh
./build.sh --arch amd64 --binary ./dist/caddy-linux-amd64
./build.sh --arch arm64 --binary ./dist/caddy-linux-arm64
```

也可以把二进制直接命名为 `./caddy` 再执行：

```bash
./build.sh --arch amd64
```

生成产物：

- `caddy-alidns-linux-amd64.run`
- `caddy-alidns-linux-arm64.run`
- 对应的 `.sha256`

### 方式二：走 GitHub Actions

触发方式：

- 推送 `v*` tag
- 手动触发 `workflow_dispatch`

流水线会做：

1. 用 `xcaddy` 构建 `amd64 / arm64`
2. 校验 `dns.providers.alidns` 模块
3. 调用 `build.sh` 打 `.run`
4. 上传 artifact
5. 如果是 tag，则自动发 GitHub Release

## 安装命令

### 1. 先做预检查

```bash
chmod +x ./caddy-alidns-linux-amd64.run
sudo ./caddy-alidns-linux-amd64.run precheck \
  --ak your_ak \
  --sk your_sk \
  --listen image.hm.metavarse.tech \
  --backend 127.0.0.1:8080
```

### 2. Harbor 这类单域名反向代理

```bash
sudo ./caddy-alidns-linux-amd64.run install \
  --ak your_ak \
  --sk your_sk \
  --email ops@example.com \
  --listen image.hm.metavarse.tech \
  --backend 127.0.0.1:8080 \
  --site-template harbor \
  --max-body 0 \
  --force
```

说明：

- `--site-template harbor`
  - 只是一个语义化模板名，便于后续维护
- `--max-body 0`
  - 表示不限制请求体，更适合 Harbor 推镜像
- `--force`
  - 如果检测到历史文件被人工改过，会先备份再覆盖

### 3. 普通反向代理站点

```bash
sudo ./caddy-alidns-linux-amd64.run install \
  --ak your_ak \
  --sk your_sk \
  --email ops@example.com \
  --listen api.example.com \
  --backend 127.0.0.1:8080
```

### 4. 泛域名底座

```bash
sudo ./caddy-alidns-linux-amd64.run install \
  --ak your_ak \
  --sk your_sk \
  --email ops@example.com \
  --wildcard '*.example.com' \
  --enable-metrics
```

这个模式会先把泛域名证书和底座入口跑起来，后续每个业务再单独加自己的站点文件。

## 配置文件方式

为了避免 AK/SK 出现在 shell history 里，推荐用 `--config`。

示例 `deploy.conf`：

```bash
AK=your_access_key_id
SK=your_access_key_secret
EMAIL=ops@example.com
LISTEN=image.hm.metavarse.tech
BACKEND=127.0.0.1:8080
SITE_TEMPLATE=harbor
MAX_BODY=0
ENABLE_METRICS=1
```

执行：

```bash
sudo ./caddy-alidns-linux-amd64.run install --config ./deploy.conf --force
```

## 安装后的辅助命令

安装完成后会自动放这几个工具：

- `caddy-test-runtime`
  - 检查 systemd、Caddy 版本、AliDNS 模块和配置语法
- `caddy-test-certificate`
  - 用 `openssl` 和 `curl` 检查证书是否已下发、TLS 是否可用
- `caddy-site-init`
  - 生成新的站点文件并自动校验 / reload

### 运行状态检查

```bash
caddy-test-runtime
```

### 证书检查

```bash
caddy-test-certificate --domain image.hm.metavarse.tech
```

如果监听的是非标准端口，例如 `9443`：

```bash
caddy-test-certificate \
  --domain image.hm.metavarse.tech \
  --connect-host localhost \
  --connect-port 9443
```

### 新增一个业务站点

```bash
sudo caddy-site-init \
  --domain api.example.com \
  --backend 127.0.0.1:8081
```

Harbor 类型站点可以这样生成：

```bash
sudo caddy-site-init \
  --domain harbor.example.com \
  --backend 127.0.0.1:8080 \
  --template harbor \
  --max-body 0
```

## 工程化约定

这版重点修掉了你前面碰到的几类问题：

- 不再生成旧版 `log` 错误写法
  - 现在是全局 `log { output stderr; format json; level INFO }`
- 不再把 `metrics` 塞进 `servers` 里
  - 现在用新版全局 `metrics`
- 不再在站点里重复写老式 `tls { dns ... propagation_timeout ... }`
  - 改成全局 `acme_dns alidns`
- 安装前强制做 `caddy validate`
- 安装脚本支持幂等
  - 文件相同则跳过
  - 文件不同但未加 `--force` 时，生成 `.dist`
  - 加 `--force` 时自动备份旧文件再覆盖

## 推荐发布方式

如果你已经确认这版没问题，建议按下面流程发版：

```bash
git status
git add .
git commit -m "feat: rebuild caddy offline installer"
git push origin main
git tag v2.11.2-1
git push origin v2.11.2-1
```

说明：

- `push main`
  - 更新仓库内容
- `push tag`
  - 触发 GitHub Release 流水线

如果你想继续沿用别的版本号规则，也可以把 tag 改成你自己的风格，只要满足 `v*` 即可。
