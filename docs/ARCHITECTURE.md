# 架构

- `YabaibyeCore`：纯编号路由、物理键位映射、等权多叉分区树、落点区域与方向邻居选择。默认近方阵，三窗口为左侧上下、右侧满高的等宽两列，四窗口为 2×2；删去源窗口后折叠空组，同轴分区合并，从而形成等宽行列。
- `DragTiling`：30Hz 观察鼠标左键状态及 AX 窗口位移；只有真实移动窗口时显示 `DropOverlay`，松手后提交布局。尺寸变化视为调整大小，不触发分割。只处理同一 Space 的平铺窗口；暂停、权限撤销、Space 切换、窗口消失时清理蒙版。
- `DropOverlay`：不激活、不接收鼠标的 NSPanel，低饱和红色半透明底和斜向虚线；按 AX 顶部原点转为 AppKit 坐标。
- `DragPractice`：三个隔离的原生测试窗口，使用相同管理器与拖拽流程，关闭任意一个就结束练习并恢复原来的管理状态。
- `SpaceBridge`：Objective-C 桥接，动态解析 SkyLight / AX 窗口 ID，私有符号缺失时返回不可用，不因静态链接失败而崩溃。
- `Spaces`：Space 快照、系统左右桌面快捷键、Mission Control AX 导航、可验证的 WindowManager 桥接移窗。macOS 27 的 `mc.display` 位于 WindowManager 根节点，旧版位于 Dock 的 `mc` 容器。包括超时、取消和指针恢复。
- `Windows`：AX 标准窗口枚举，以 CG 可见列表 + 单 Space 归属过滤，排除桌面、弹窗、全屏和共享窗口。
- `WindowManager`：主线程串行操作，0.8 秒轮询可见窗口；仅对策略中的平铺成员协调布局，新增浮动窗口不触发重排。布局成员或工作区改变时重排，Space 操作期间暂停布局更新与新快捷键命令。
- `WindowTilingPolicy`：记录本登录会话的显式平铺成员，未知窗口默认浮动。首次建立基线通过 `Windows.existingWindowIDs()` 纳入已有窗口，含其他 Space 和最小化窗口；之后仅显式切换修改成员，暂时不可见不删除归属。停止 / 重启管理保留策略，新登录会话重新建立基线。浮动恢复用的 `originalFrames` 仅保留于当前应用运行。
- `Hotkeys`：Carbon `RegisterEventHotKey`，不是全局键盘录制；注册任一键失败便整体撤销。
- `AppDelegate`：菜单栏、授权入口、登录项、诊断与首次使用说明。
- `SmokeTest`：用户主动运行的真实窗口/Space 集成测试，恢复桌面且保留独立的 SIP 验收要求。

权限仅为辅助功能；不读取窗口内容或标题作为持久化日志，不发送网络请求。标准 macOS 登录项通过 `SMAppService` 管理。

当前阶段不包含：任意分区比例配置、电脑重启或窗口重建后的身份匹配、Space 自动创建/删除、窗口透明度、动画关闭、焦点跟随鼠标。

窗口帧调整会临时关闭目标进程的 AXEnhancedUserInterface（仅当原来开启时），在结束/取消时恢复；这是避免辅助功能动画干扰几何更新的兼容处理。尺寸、位置、尺寸分阶段提交并等待稳定后读取实际值验证。

- `LayoutSpacing`：两个独立的 0–100 pt 偏好，UserDefaults 保存并校验；布局签名包含留白，因此忙碌时延迟的修改会在下次刷新应用。
- `SpacingSettings`：原生滑块/数值输入与缩放预览；不另存一份布局状态。
- `ForegroundPolicy` / `ForegroundKeeper`：按前后顺序与几何重叠判断普通后台窗口遮挡；只 Raise 当前前台焦点窗口，重新检查前台 PID 后执行，不激活应用或更改窗口等级。系统浮层及当前应用自己的窗口优先保留。

- `ShortcutPreferences` / `ShortcutSettings`：28 项操作的可持久化物理键位与修饰键；先验证完整命令表及去重，再注册新组合，失败回滚旧注册。帮助页及放大菜单从当前配置生成。
- `LayoutPersistence`：在同一 archive 保存 Codable 分区树、customized 标记及可选 tilingPolicy；旧档案缺策略时仍读取布局，并在启用时建立成员基线。分区树以显示器 UUID + Space ID 分区，boot UUID / loginwindow PID / UID 限定会话；只存窗口 PID/ID，不存窗口标题。刷新成员变化、拖拽、方向交换后保存。恢复后重算当前屏幕几何；reconcile 对 customized=false 的自动树按当前默认规则重建，即使成员未变，customized=true 的手动树保留分区结构。练习不持久化，自检注入独立 UserDefaults suite，不覆盖用户布局。

## 安全与失败恢复

- 构建启用 Hardened Runtime，不添加运行时例外 entitlement；`verify_security.sh` 检查签名完整性、runtime 标志及例外，CI 构建也执行。使用系统框架，不允许任意第三方库注入；这不替代 Developer ID 公证。
- `WindowSnapshot` 区分成功枚举、确认排除和读取失败。受影响显示器跳过本次布局协调及保存；Space 归属读取失败也跳过刷新，保留最后确认的分区。
- `LayoutApplication` 仅在 AX 写入且实际几何核验成功后缓存已应用布局。失败或取消使缓存失效，同一请求按 1、2、4、8、15 秒退避重试；新布局和显式刷新可立即重试。
- 放大窗口最小化、应用隐藏或进入原生全屏时，释放该 Space 的放大状态，让剩余窗口继续平铺。
- 练习和自检管理器限制窗口身份集合及焦点来源，不注册全局快捷键、不改用户启用偏好；自检单独短暂验证快捷键注册后立即释放。
- 只有通过单实例检查的主实例拥有退出清理和偏好保存责任；被拒绝的重复实例直接退出。
