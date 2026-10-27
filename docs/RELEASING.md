# 发布与安装

版本唯一来源为仓库根目录 `version.json`。开发命令 `./script/build_and_run.sh` 使用当前版本生成 Debug 包，不升版；正式包与应用诊断均读取同一版本来源。

## 本机一键公证发布（推荐）

签名私钥和公证凭证保存在本机钥匙串，不上传 GitHub Secrets。先将已验证的配置名称写入仓库根目录 `.release-local.json`（已被 Git 忽略，不填写密码或私钥）：

```json
{
  "identity": "Developer ID Application: Your Name (TEAMID)",
  "notary_profile": "your-keychain-profile"
}
```

也可使用 `YABAIBYE_RELEASE_IDENTITY` 和 `YABAIBYE_NOTARY_PROFILE` 环境变量覆盖。运行此入口需 Python 3.11+，GitHub CLI 需已登录，并且 `main` 的工作区干净、已与 `origin/main` 同步；先完成并推送产品代码，再运行发布。

```sh
# 只检查配置和发布条件，不打包、不升版、不上传
python3 script/publish_release.py --check

# 测试、自动升版、通用架构打包、正式签名、公证、推送版本与上传 Release
python3 script/publish_release.py

# 上传或网络中断后继续同一次发布，不重复递增版本
python3 script/publish_release.py --resume
```

默认递增补丁版本和构建号，也支持 `--bump minor` / `major` / `build`。正式发布要求 Developer ID 签名与 Apple 公证成功，不会降级为未公证包；只自动提交 `version.json`。发布过程使用 GitHub 草稿暂存附件，确认后再公开；恢复时校验源码、标签和产物，遇到不一致即停止。发布状态保存在被忽略的 `dist/` 内。

此命令会向 Apple 提交应用与 DMG，并向 GitHub 推送版本和上传附件；不会自动替换本机应用或关闭正在使用的窗口管理器。首次访问签名私钥时，macOS 可能要求本机密码授权。证书私钥、公证密码不得进入配置、日志或仓库。

## 正式打包

```sh
python3 script/package_release.py
```

默认执行打包脚本回归和 Swift 测试，编译 `release` 配置的 arm64 / x86_64 通用二进制，检查架构、Hardened Runtime 与签名，再生成 DMG、ZIP、SHA256SUMS 和 release.json。产物保存在 `dist/releases/<version>-<build>-universal/`，不会自动安装、退出正在运行的应用或发布到网络。

默认将补丁号和构建号各加一。例如 `0.1.0 (1)` → `0.1.1 (2)`。`--bump minor` / `major` / `build` 分别升级小版本、大版本或只增加构建号。默认无公证；可用 `--arch arm64` / `x86_64` 指定单架构。

脚本使用进程锁串行打包，不覆盖同名输出。构建、签名、压缩或公证失败时不会推进版本；完成本地发布后才原子更新 version.json。极端断电若留下孤立版本目录，先检查完整性并移到备份位置，再重试，不能直接覆盖。

## 仓库下载

优先使用上面的本机公证发布命令。作为可选的未公证流程，对 main 手动运行 GitHub Actions 的 **Release** 工作流，选择版本增量，即可测试、打包、提交版本文件并创建 GitHub Release。这条工作流仅由人工触发；普通 push / PR 的 CI 仍是开发验证，不自动升版。工作流当前明确发布未公证包，使用仓库 token，不需要上传本机证书。

本地打包后提交本次源码与 `version.json`，再使用 `gh release create` 发布 DMG、ZIP、SHA256SUMS、release.json。标签格式为 `v<version>+<build>`，发布必须指向该源码提交。不要把 `.app`、DMG 或 ZIP 提交进 Git 历史；使用 Releases 附件。

## 签名与公证

首个公开版本 `0.1.2 (3)` 使用临时签名（ad-hoc），未经 Apple 公证。`0.1.3 (4)` 通过本机 Developer ID 签名和公证流程发布；GitHub Actions 的 Release 工作流尚未配置证书及公证凭证，仍生成未公证包。每份产物的签名、公证状态记录在其 `release.json` 和发布说明中。

所有包启用 Hardened Runtime 和默认库校验，无放宽运行时保护的 entitlement。未公证下载包可能被 Gatekeeper 或组织策略拦截；不提供移除 quarantine、关闭 Gatekeeper 或关闭 SIP 的方法。

使用自己的 Developer ID Application 身份及本机 Keychain 公证配置生成已公证包：

```sh
YABAIBYE_RELEASE_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
YABAIBYE_NOTARY_PROFILE='your-keychain-profile' \
python3 script/package_release.py
```

脚本分别提交应用 ZIP 与 DMG，要求状态为 Accepted，装订并验证票据。失败不自动降级为未公证发布。Apple Development / Apple Distribution 不是此类站外分发证书，脚本会拒绝用它们冒充 Developer ID。不要将证书私钥或凭证写进仓库。

## 本机安装与登录启动

打开 DMG，将应用复制到 `/Applications/Yabaibye.app`，从固定安装位置运行。首次授权辅助功能后，点击启用管理。主窗口的“开启登录启动”通过 `SMAppService.mainApp` 注册；状态须为“已开启”，若待批准则先在系统登录项设置批准。macOS 登录启动仍要求用户登录后才运行；安装验证不通过注销或重启打断用户工作。

从源码路径改到 Applications、临时签名更新或从 ad-hoc 切换到 Developer ID 身份时，系统可能要求再次授权。更新时正常退出旧应用，再替换完整应用包；需要回退时先保留上一份完整应用。偏好及布局不随包替换而删除。

## 应用内更新

菜单栏提供“检查更新…”与“自动检查更新”。自动检查默认开启；启动 30 秒后及每小时判断是否距离上次检查满 24 小时。发现新版本后，用户确认“下载并更新”才下载、安装并重启 Yabaibye；其他应用保持运行。下载期间可取消。

更新直接使用本仓库 GitHub Releases 的 `release.json`、`SHA256SUMS` 和 ZIP，无额外更新服务或签名密钥。仅安装同一 Developer ID Team 签名、通过 Gatekeeper 验证的已公证正式版本；检查 bundle ID、版本、CPU 架构、最低系统版本及 SHA-256。开发/临时签名包和未公证 Actions 发布不自动替换。应用须位于可写的 `/Applications/Yabaibye.app` 或 `~/Applications/Yabaibye.app`；其他位置提示手动安装，不请求管理员权限。

安装助手由当前已签名可执行文件复制而来，使用权限 0700 的独立临时目录，等待主应用正常退出后再次验证候选包和当前包。在目标磁盘暂存并验证，依次重命名旧、新应用，启动请求失败则恢复并重新打开旧版本。失败信息在下次启动显示；下载和校验失败不会触碰已安装应用。ZIP 解压前验证路径、文件类型、local header 与中央目录一致性及总大小，不允许符号链接、路径穿越或任意下载脚本。

首次包含该功能的正式版本仍需手动安装；之后的正式发布沿用现有公证发布命令即可。源码测试覆盖版本/发布/校验规则、真实 ditto ZIP、路径限制和替换回滚；跨版本端到端验收应使用两个独立的已签名、公证测试版本，并确认辅助功能授权、登录启动及窗口布局偏好保留。
