# 发布与安装

版本唯一来源为仓库根目录 `version.json`。开发命令 `./script/build_and_run.sh` 使用当前版本生成 Debug 包，不升版；正式包与应用诊断均读取同一版本来源。

## 正式打包

```sh
python3 script/package_release.py
```

默认执行打包脚本回归和 Swift 测试，编译 `release` 配置的 arm64 / x86_64 通用二进制，检查架构、Hardened Runtime 与签名，再生成 DMG、ZIP、SHA256SUMS 和 release.json。产物保存在 `dist/releases/<version>-<build>-universal/`，不会自动安装、退出正在运行的应用或发布到网络。

默认将补丁号和构建号各加一。例如 `0.1.0 (1)` → `0.1.1 (2)`。`--bump minor` / `major` / `build` 分别升级小版本、大版本或只增加构建号。默认无公证；可用 `--arch arm64` / `x86_64` 指定单架构。

脚本使用进程锁串行打包，不覆盖同名输出。构建、签名、压缩或公证失败时不会推进版本；完成本地发布后才原子更新 version.json。极端断电若留下孤立版本目录，先检查完整性并移到备份位置，再重试，不能直接覆盖。

## 仓库下载

对 main 手动运行 GitHub Actions 的 **Release** 工作流，选择版本增量，即可测试、打包、提交版本文件并创建 GitHub Release。只有这条人工触发的工作流会发布；普通 push / PR 的 CI 仍是开发验证，不自动升版。工作流当前明确发布未公证包，使用仓库 token，不需要上传本机证书。

本地打包后提交本次源码与 `version.json`，再使用 `gh release create` 发布 DMG、ZIP、SHA256SUMS、release.json。标签格式为 `v<version>+<build>`，发布必须指向该源码提交。不要把 `.app`、DMG 或 ZIP 提交进 Git 历史；使用 Releases 附件。

## 签名与公证

首个版本使用临时签名（ad-hoc），启用 Hardened Runtime 和默认库校验，无放宽运行时保护的 entitlement。它是优化后的 Release 包，**并不等于 Apple 已公证的可信分发包**。下载后可能被 Gatekeeper 或组织策略拦截；不提供移除 quarantine、关闭 Gatekeeper 或关闭 SIP 的方法。

以后准备好自己的 Developer ID Application 身份及本机 Keychain 公证配置后：

```sh
YABAIBYE_RELEASE_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
YABAIBYE_NOTARY_PROFILE='your-keychain-profile' \
python3 script/package_release.py
```

脚本分别提交应用 ZIP 与 DMG，要求状态为 Accepted，装订并验证票据。失败不自动降级为未公证发布。Apple Development / Apple Distribution 不是此类站外分发证书，脚本会拒绝用它们冒充 Developer ID。不要将证书私钥或凭证写进仓库。

## 本机安装与登录启动

打开 DMG，将应用复制到 `/Applications/Yabaibye.app`，从固定安装位置运行。首次授权辅助功能后，点击启用管理。主窗口的“开启登录启动”通过 `SMAppService.mainApp` 注册；状态须为“已开启”，若待批准则先在系统登录项设置批准。macOS 登录启动仍要求用户登录后才运行；安装验证不通过注销或重启打断用户工作。

从源码路径改到 Applications 或临时签名更新时，系统可能要求再次授权。更新时正常退出旧应用，再替换完整应用包；需要回退时先保留上一份完整应用。偏好及布局不随包替换而删除。
