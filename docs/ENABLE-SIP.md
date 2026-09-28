# 开启 SIP（Apple Silicon）

Yabaibye 不会替你修改 SIP 或自动重启。开启 SIP 必须在恢复环境由本机用户完成。

1. 保存工作，关机。
2. 按住电源键，直到出现启动选项。
3. 选择“选项”→“继续”，按提示选择管理员账户。
4. 在恢复环境的菜单栏选择“实用工具”→“终端”。
5. 执行：

   ```sh
   csrutil enable
   ```

6. 按系统提示确认并重启。
7. 回到 macOS 后验证：

   ```sh
   csrutil status
   ```

   应明确显示 `System Integrity Protection status: enabled.`。`unknown (Custom Configuration)` 不算完整启用。

8. 启动 Yabaibye，检查辅助功能权限，运行窗口与 Space 自检，再启用管理。

这里只需恢复 SIP。不要为此卸载系统文件、修改启动参数或降低启动安全策略。

Apple 官方资料：[配置 SIP](https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/ConfiguringSystemIntegrityProtection/ConfiguringSystemIntegrityProtection.html)、[Apple Silicon 启动方式](https://support.apple.com/en-ie/102603)。
