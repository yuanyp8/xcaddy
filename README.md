# Caddy + AliDNS 构建器

自动构建集成阿里云 DNS 插件的 Caddy 多架构二进制文件。

## 构建产物

| 平台 | 文件名 |
|------|--------|
| Linux x86_64 | `caddy-linux-amd64` |
| Linux ARM64 | `caddy-linux-arm64` |
| Linux ARMv7 | `caddy-linux-armv7` |
| macOS Intel | `caddy-darwin-amd64` |
| macOS Apple Silicon | `caddy-darwin-arm64` |
| Windows x86_64 | `caddy-windows-amd64.exe` |

## 如何触发构建

### 方式一：打 Tag 自动发布
```bash
git tag v1.0.0
git push origin v1.0.0