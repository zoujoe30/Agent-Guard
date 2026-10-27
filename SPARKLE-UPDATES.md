# Sparkle 更新包制作

Agent Guard 固定使用 Sparkle 2.10.1。`build-app.sh` 从 SwiftPM 二进制依赖中复制完整 framework，保留版本目录、符号链接、可执行权限及所有安装组件。脚本依次签名 Mach-O 文件、XPC 服务、Updater.app、framework 和主应用，再对完整签名及压缩后的应用进行核验。`--deep` 仅用于核验。Sparkle 及其外部组件许可证随源码和应用一起提供。

## 发布准备

1. 使用项目原有构建入口生成 ZIP。Sparkle 安装用 ZIP 内仅包含 `Agent Guard.app`，不使用安装 PKG。
2. 确保应用 `SUPublicEDKey` 与本机登录钥匙串中的 Sparkle Ed25519 公钥一致。私钥保留在钥匙串；更新脚本不生成、读取或导出私钥。首次配置密钥应单独完成。
3. 为 GitHub Release 选定最终 tag 与 ZIP 文件名，再执行：

```sh
python3 Tools/prepare-sparkle-update.py \
  --zip '/absolute/output/Agent.Guard-0.3.21.zip' \
  --version 0.3.21 --build 32 \
  --download-url 'https://github.com/zoujoe30/Agent-Guard/releases/download/local-0.3.21-build32/Agent.Guard-0.3.21.zip' \
  --sign-update '/absolute/Sparkle-2.10.1/bin/sign_update' \
  --keychain-account com.local.agentguard.sparkle \
  --output-dir '/absolute/output/updates'
```

`--keychain-account` 可指定另一个已配置的 Sparkle 钥匙串账户；默认 `ed25519`。脚本需要 Python 3.9+、Swift 与 macOS CryptoKit（构建应用时已有 Swift）。它核对 ZIP 路径、唯一应用、bundle ID、版本、build、嵌入 framework、公钥、HTTPS GitHub release 下载地址与文件名，使用官方工具从钥匙串签名 ZIP，并用 ZIP 中公钥独立核验签名。随后生成和签名 `appcast.xml`、回验 feed 签名，并生成 ZIP 与最终 feed 的 `SHA256SUMS.txt`。

输出目录必须为空，防止覆盖已签名 feed。脚本仅创建单一当前版本 item；新版本的 build 必须递增。它不会上传或发布文件。

4. 复核 ZIP、已签名 `appcast.xml` 与 `SHA256SUMS.txt`，再通过项目发布流程上传。GitHub Release 的 ZIP 地址必须与 enclosure URL 完全一致；appcast 发布位置必须与应用中的 `SUFeedURL` 一致。先使 ZIP 可下载，再更新 feed。任何修改 feed 的操作都需要重新签名并重算哈希。
5. 用真实较低 build 的应用验证发现更新、下载、签名、安装、重启和权限保持。托管或认证进行时应禁止安装，并确认恢复空闲后仅继续用户已经明确选择的安装；未经用户选择不自动安装。

## 分发边界

Sparkle EdDSA 签名与 macOS 代码签名承担不同作用，二者都需保留。当前本地证书预发布包并非 Apple Developer ID 公证发行。公开稳定发行应使用 `AGENT_GUARD_DISTRIBUTION=1` 和 Developer ID Application 签名身份，并完成公证。脚本不自动升级签名身份、不自动公证、不发布 GitHub Release。

旧版 0.3.20 及之前没有 Sparkle，用户需先手动安装含 Sparkle 的版本，之后才能收到应用内更新提示。

参考：[Sparkle 基础集成](https://sparkle-project.org/documentation/)、[更新发布](https://sparkle-project.org/documentation/publishing/)。

本项目更新源为 `https://raw.githubusercontent.com/zoujoe30/Agent-Guard/main/updates/appcast.xml`。签名账户为 `com.local.agentguard.sparkle`，私钥只保存在本机登录钥匙串；迁移或丢失该密钥会影响后续更新签名，发布前应由维护者在安全位置备份。不要把私钥、钥匙串导出或本机证书写入仓库。

## 无私钥的发布核验

发布前或 CI 可以不使用钥匙串，执行：

```sh
python3 Tools/verify-sparkle-update.py \
  --appcast /absolute/updates/appcast.xml \
  --zip '/absolute/output/Agent.Guard-0.3.21.zip' \
  --public-key 'TRUSTED_SUPublicEDKey_FROM_PREVIOUS_RELEASE' \
  --download-url 'https://github.com/OWNER/REPOSITORY/releases/download/TAG/Agent.Guard-0.3.21.zip'
```

公钥应来自已信任的旧版或受控源码/CI 配置；不要从待验证 ZIP 自动取公钥作为信任来源。验证器使用 CryptoKit 验证 feed 和 ZIP 两层签名，同时比对 ZIP 内公钥、bundle ID、version、build、文件名、下载 URL 和长度。它只读输入，不联网、不调用钥匙串。`test.sh` 包含使用一次性测试密钥的离线回归，不接触发布密钥。
