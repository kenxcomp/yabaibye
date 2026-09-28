# 架构

- `YabaibyeCore`：纯编号路由、物理键位映射、平铺几何与方向邻居选择，可单元测试。
- `SpaceBridge`：Objective-C 桥接，动态解析 SkyLight / AX 窗口 ID，私有符号缺失时返回不可用，不因静态链接失败而崩溃。
- `Spaces`：Space 快照、系统左右桌面快捷键、Mission Control AX 导航、可验证的 WindowManager 桥接移窗。macOS 27 的 `mc.display` 位于 WindowManager 根节点，旧版位于 Dock 的 `mc` 容器。包括超时、取消和指针恢复。
- `Windows`：AX 标准窗口枚举，以 CG 可见列表 + 单 Space 归属过滤，排除桌面、弹窗、全屏和共享窗口。
- `WindowManager`：主线程串行操作，0.8 秒轮询可见窗口；布局成员或工作区改变时重排。Space 操作期间暂停布局更新与新快捷键命令。
- `Hotkeys`：Carbon `RegisterEventHotKey`，不是全局键盘录制；注册任一键失败便整体撤销。
- `AppDelegate`：菜单栏、授权入口、登录项、诊断与首次使用说明。
- `SmokeTest`：用户主动运行的真实窗口/Space 集成测试，恢复桌面且保留独立的 SIP 验收要求。

权限仅为辅助功能；不读取窗口内容或标题作为持久化日志，不发送网络请求。标准 macOS 登录项通过 `SMAppService` 管理。

当前阶段不包含：自定义快捷键、复杂布局配置、跨重启窗口身份持久化、Space 自动创建/删除、窗口透明度、动画关闭、焦点跟随鼠标。

窗口帧调整会临时关闭目标进程的 AXEnhancedUserInterface（仅当原来开启时），在结束/取消时恢复；这是避免辅助功能动画干扰几何更新的兼容处理。尺寸、位置、尺寸分阶段提交并等待稳定后读取实际值验证。
