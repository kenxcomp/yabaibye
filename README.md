# Yabaibye

原生 macOS 菜单栏窗口管理器，以保持 **SIP 开启**为设计目标。Swift + AppKit，内置快捷键，不依赖 yabai、skhd、Hammerspoon，也不向 Dock 注入代码。

**0.1.0 开发预览**：原生 Space 操作使用未公开的 SkyLight 查询、WindowManager 移窗桥接接口和 Mission Control 辅助功能。它们不是 Apple 保证稳定的 API。已在 macOS 27.2（26B5091g）、完整 SIP 开启、双屏环境通过窗口及 Space 自检，见[验证记录](docs/VALIDATION.md)。其他环境请运行菜单里的自检，不能用编译成功替代。

## 快捷键

| 快捷键 | 功能 |
|---|---|
| `⌥ A S D F G H J K L` | 按主行从左到右 跳转普通 Space 1–9 |
| `⌥ ⇧ A S D F G H J K L` | 将前台应用的当前窗口移到 Space 1–9 |
| `⌥ T` | 前台窗口在平铺 / 浮动间切换 |
| `⌥ Return` | 当前窗口铺满桌面可用区域 / 再按恢复 |
| `⌥ [` / `⌥ ]` | 当前窗口所在屏幕的前一个 / 后一个 Space |
| `⌥ ⇧ [` / `⌥ ⇧ ]` | 第二块屏幕的前一个 / 后一个 Space |
| `⌥ ← ↑ ↓ →` | 与指定方向的平铺窗口交换位置 |

- 编号按 WindowServer / Mission Control 的显示器、桌面顺序跨屏统一排列。直接编号跳过全屏 Space；相邻导航包含全屏 Space。
- 第二块屏幕是 Space 列表里的第二个显示器，并非“当前屏幕以外的任意屏幕”。
- 相邻导航到边界即停止，不循环。不存在的编号会提示，不自动创建桌面。
- 使用物理 ANSI 键位，中文输入法下也可用；其他键盘布局上的印字可能不同。
- 默认优先网格：三个窗口为等宽三列，四个窗口为 2×2「田」字，更多窗口按接近方阵的列数排列，默认留 10pt 间隙。
- 拖动平铺窗口的标题栏到同一 Space 的其他平铺窗口：中心交换位置，上/下/左/右边缘分割；低饱和红色半透明蒙版与斜向虚线预览落点，不拦截鼠标、不抢焦点。四边占目标宽/高的外侧 25%，中间区域用于交换，角落按最近的相对边缘判断。
- 分区的同方向兄弟区域会合并等分。例如 `A B C` → A 拖到 B 下方：左侧 B/A 上下平分，右侧 C；再把 A 拖到 C 右侧：恢复 `B C A` 等宽三列。
- 手动分区按显示器与 Space 自动保存，重启 Yabaibye 后为仍然打开的窗口恢复；窗口关闭/最小化/浮动后移除对应格子并合并空分区，新窗口加入外层分区。方向快捷键按当前自定义布局交换。记录限定当前系统登录会话，不承诺电脑重启或应用关闭后重新创建的窗口恢复。
- 松手在无效区域会回到原分区；拖拽中按 Escape 取消落点。窗口跨屏/跨 Space 拖动由系统处理，不显示跨 Space 分割蒙版。
- 放大保留菜单栏和 Dock，不创建 macOS 全屏 Space。再次按 `⌥Return` 恢复原平铺分区；浮动窗口恢复原位置/尺寸。放大期间暂不重排该桌面的其他窗口，其他屏幕不受影响。
- 浮动恢复该窗口本次运行中平铺前的尺寸。状态按窗口保存，退出后重置。

菜单栏 → **快捷键设置…**：28 项操作均可独立选择按键和 Option / Shift / Control / Command。点击 **保存快捷键** 即时生效并持久化；支持恢复默认。至少包含 Option、Control 或 Command 中的一个。重复组合或注册冲突会报错，保存失败保持原配置并尝试恢复原注册；若原注册也无法恢复则暂停管理并提示。默认迁移到主行，已保存的自定义配置不会被后续升级覆盖。

## 留白与前台窗口

菜单栏 → **平铺留白…**（说明窗口也有入口）：屏幕边缘留白和窗口间距独立调整，范围 0–100 pt，默认各 10 pt。支持滑块、数值输入和无留白/默认/宽松预设，预览即时更新，设置自动保存并在下次启动恢复。应用于所有屏幕与 Space 的平铺布局，保留分区结构；浮动窗口不变。拖动中或正在调整几何时延后应用，空间不足时会缩小留白以保持窗口在屏幕内。

**保持前台窗口在上层**默认开启，也可在菜单或留白窗口关闭。检测到后台普通窗口遮挡时，对当前前台应用的焦点窗口执行 AX Raise；不切换焦点、不改变系统窗口层级，并避开拖拽和 Mission Control。当前应用自己的弹窗、系统提示、特殊浮层不会被强行覆盖；其他程序主动抢焦点不属于此开关的保护范围。

自检完成后保存结果并更新状态，可从菜单 **查看上次自检结果…** 主动打开；不再自动弹出结果窗口。自检过程本身仍需创建测试窗口和切换 Space。

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
5. 菜单栏可暂停、重新平铺、打开三个独立测试窗口练习拖拽、查看 Space 列表、复制不含窗口标题的诊断、开关登录时启动，以及运行自检。

本机构建默认使用临时签名，修改代码重签名后系统可能要求重新授权辅助功能。使用自己的稳定签名身份可设置 `YABAIBYE_SIGN_IDENTITY`，或在被 Git 忽略的 `.signing-identity` 文件中写入签名身份。尚未进行 Developer ID 公证；不提供绕过 Gatekeeper 的安装步骤。

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

- 编号快捷键 与菜单的编号跳转直接在 Mission Control 选择目标桌面，不逐个经过中间桌面。会短暂显示 Mission Control，保留系统动画。`⌥ [/ ]`（含第二屏版本）仍优先使用系统左右桌面快捷键；不可用时才回退到 Mission Control。
- 移窗优先使用运行时解析的 `SLSBridgedMoveWindowsToManagedSpaceOperation`，支持同屏及跨屏；保持当前桌面，查询窗口归属后才报告成功。旧系统仅尝试同屏兼容接口，无法验证时明确报错。不会模拟拖拽。
- 全屏、最小化、对话框和“所有桌面”共有窗口不参与平铺/移窗。
- 系统或应用最小尺寸可能使实际窗口偏离理想平铺格；使用 `⌥T` 将此类窗口浮动。
- 私有接口缺失或 Mission Control AX 结构变化会明确报错，不伪报成功，不要求关闭 SIP。
- 无管理员守护进程、Dock 注入、scripting addition、内核扩展或 SIP 修改。

## 验证

`swift test` 检查跨屏编号、全屏过滤与 AX 索引对应、导航边界、28 个快捷键不冲突、布局不越界不重叠，以及方向邻居选择。

应用菜单 → **运行窗口与 Space 自检**：先暂停管理，仅创建测试窗口，验证真实 AX 移动/缩放、生产命令的浮动与方向交换、各屏原生 Space 切换、同屏及跨屏移窗后的真实归属；关闭测试窗口后恢复原来的活动 Space。**自检不自动重新启用管理**，结果里 `SKIP`/`FAIL` 不算通过。

菜单 → **布局自检（不切换桌面）** 只创建独立测试窗口，验证放大/恢复、浮动、方向交换、拖拽分区和管理器重建后的布局恢复；使用独立偏好存储，结束后恢复原管理状态。

更多： [验收清单](docs/ACCEPTANCE.md) · [启用 SIP](docs/ENABLE-SIP.md) · [架构](docs/ARCHITECTURE.md)。

## 致谢

原生 Space 能力的兼容性研究参考了 [Hammerspoon 的 hs.spaces 文档](https://www.hammerspoon.org/docs/hs.spaces.html)、[SkyLight 声明与兼容方法](https://github.com/Hammerspoon/hammerspoon/tree/master/extensions/spaces)、[yabai 的 Space 实现](https://github.com/asmvik/yabai/blob/master/src/space_manager.c) 和 [DockDoor 的桥接 API 研究](https://github.com/ejbills/DockDoor/blob/main/DockDoor/Utilities/PrivateApis.swift)。Yabaibye 是独立应用，没有捆绑这些项目。

MIT License.
