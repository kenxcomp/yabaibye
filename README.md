# Yabaibye

原生 macOS 菜单栏窗口管理器，以保持 **SIP 开启**为设计目标。Swift + AppKit，内置快捷键，不依赖 yabai、skhd、Hammerspoon，也不向 Dock 注入代码。

**0.1.0 开发预览**：原生 Space 操作使用未公开的只读 SkyLight 接口、Mission Control 辅助功能和移窗兼容接口/拖拽回退。它们不是 Apple 保证稳定的 API。请运行菜单里的自检；完整 SIP 环境的结果必须独立验证，不能用编译成功替代。

## 快捷键

| 快捷键 | 功能 |
|---|---|
| `⌥ A… I` | 按 `a b c d e f g h i` 跳转普通 Space 1–9 |
| `⌥ ⇧ A… I` | 将前台应用的当前窗口移到 Space 1–9 |
| `⌥ T` | 前台窗口在平铺 / 浮动间切换 |
| `⌥ [` / `⌥ ]` | 当前窗口所在屏幕的前一个 / 后一个 Space |
| `⌥ ⇧ [` / `⌥ ⇧ ]` | 第二块屏幕的前一个 / 后一个 Space |
| `⌥ ← ↑ ↓ →` | 与指定方向的平铺窗口交换位置 |

- 编号按 WindowServer / Mission Control 的显示器、桌面顺序跨屏统一排列。直接编号跳过全屏 Space；相邻导航包含全屏 Space。
- 第二块屏幕是 Space 列表里的第二个显示器，并非“当前屏幕以外的任意屏幕”。
- 相邻导航到边界即停止，不循环。不存在的编号会提示，不自动创建桌面。
- 使用物理 ANSI 键位，中文输入法下也可用；其他键盘布局上的印字可能不同。
- 平铺使用沿长边递归分割的均衡布局，留 10pt 间隙。新窗口、窗口关闭、Space 切换、屏幕变化会触发重排；拖动过程中不抢鼠标。
- 浮动恢复该窗口本次运行中平铺前的尺寸。状态按窗口保存，退出后重置。

## 构建与启动

要求 macOS 14+、Swift 5.9+ / Xcode Command Line Tools。无外部包依赖。

```sh
swift test
./script/build_and_run.sh --verify
```

生成 `dist/Yabaibye.app`，首次启动处于暂停状态。可将应用复制到 `/Applications`，然后从固定位置使用。

1. 点击应用的“打开辅助功能设置”，允许 **Yabaibye**。macOS 27.2 中该页显示为 **Device Control and Data Access（设备控制与数据访问）**；旧版本位于系统设置 → 隐私与安全性 → 辅助功能。
2. 停止 yabai/skhd。应用检测到这两个进程时拒绝启用。
3. 桌面与程序坞 → Mission Control → 开启“显示器具有单独的空间”（修改后需注销）；关闭“根据最近使用情况自动重新排列空间”，以固定编号。
4. 点击菜单栏 `YB Ⅱ` → **启用窗口管理**。
5. 菜单栏可暂停、重新平铺、查看 Space 列表、复制不含窗口标题的诊断、开关登录时启动，以及运行自检。

本机构建默认使用临时签名，修改代码重签名后系统可能要求重新授权辅助功能。使用自己的稳定签名身份可设置 `YABAIBYE_SIGN_IDENTITY`。尚未进行 Developer ID 公证；不提供绕过 Gatekeeper 的安装步骤。

其他开发入口：

```sh
./script/build_and_run.sh --build-only
./script/build_and_run.sh --diagnose  # 只读 JSON，不注册快捷键、不平铺
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --debug
```

诊断模式从终端启动时可能继承终端宿主的辅助功能权限，因此其 `accessibilityTrusted` 不能替代 GUI 应用自身的授权状态。请以应用菜单和自检结果为准。

## 原生 Space 的边界

- 切换会短暂打开 Mission Control，通过目标显示器对应的 AX Space 按钮执行操作，最后重新读取当前 Space 确认结果。
- 同屏移窗先尝试运行时解析的兼容接口，并查询窗口归属验证。失败后模拟标题栏拖拽，切换并跟随到目标 Space。跨屏移窗直接使用拖拽路径。
- 拖拽期间不要操作鼠标；取消/失败会释放鼠标按键并恢复指针位置。特殊自绘标题栏、不可调整大小的窗口可能不支持。
- 全屏、最小化、对话框和“所有桌面”共有窗口不参与平铺/移窗。
- 系统或应用最小尺寸可能使实际窗口偏离理想平铺格；使用 `⌥T` 将此类窗口浮动。
- 私有接口缺失或 Mission Control AX 结构变化会明确报错，不伪报成功，不要求关闭 SIP。
- 无管理员守护进程、Dock 注入、scripting addition、内核扩展或 SIP 修改。

## 验证

`swift test` 检查跨屏编号、全屏过滤与 AX 索引对应、导航边界、27 个快捷键不冲突、布局不越界不重叠，以及方向邻居选择。

应用菜单 → **运行窗口与 Space 自检**：先暂停管理，仅创建测试窗口，验证真实 AX 移动/缩放、各屏原生 Space 切换、移窗后的真实归属；关闭测试窗口后恢复原来的活动 Space。**自检不自动重新启用管理**，结果里 `SKIP`/`FAIL` 不算通过。

更多： [验收清单](docs/ACCEPTANCE.md) · [启用 SIP](docs/ENABLE-SIP.md) · [架构](docs/ARCHITECTURE.md)。

## 致谢

原生 Space 能力的兼容性研究参考了 [Hammerspoon 的 hs.spaces 文档](https://www.hammerspoon.org/docs/hs.spaces.html)、[SkyLight 声明与兼容方法](https://github.com/Hammerspoon/hammerspoon/tree/master/extensions/spaces) 以及 [PaperWM 的拖拽回退思路](https://github.com/Hammerspoon/Spoons/tree/master/Source/PaperWM.spoon)。Yabaibye 是独立应用，没有捆绑这些项目。

MIT License.
