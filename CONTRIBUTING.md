# Contributing to Yabaibye / 参与贡献

Thanks for helping improve this macOS tiling window manager. Issues, documentation, translations, tests, and focused pull requests are welcome in English or Chinese.

欢迎用中文或英文提交问题、文档、翻译、测试和功能改进。应用界面目前为中文，英文界面与其他 macOS 版本的实测反馈尤其有帮助。

## Development setup

Follow the [README quick start](README.md#get-started) or [中文说明](README.zh-CN.md#构建与启动). This is a Swift Package Manager project with an AppKit executable and no third-party package dependencies.

```sh
swift test
./script/build_and_run.sh --build-only
```

For a local GUI session:

```sh
./script/build_and_run.sh --verify
```

The script gracefully stops a running Yabaibye instance before replacing the app bundle. Starting the app can resume window management if you previously enabled it. Use your own stable signing identity when needed; `.signing-identity` is ignored by Git. Never commit signing certificates, credentials, or local preferences.

## Making a change

- Keep a pull request focused on one problem and describe the resulting user behavior.
- Add regression coverage for routing, shortcuts, layout geometry, or persisted-state changes where appropriate.
- Keep English and Chinese README instructions consistent when changing defaults or setup.
- Preserve full-SIP operation. Do not require Dock injection or disabling system protections.
- Avoid adding window titles or document contents to logs or persistent identifiers.

For documentation-only changes, check relative links, anchors, and commands; a GUI rebuild is not required.

## Verifying macOS behavior

`swift test` covers the core model. It does not establish Accessibility permissions or native Space behavior on a particular macOS release.

When a change affects real windows, use the app's layout self-test with isolated windows. Run the full Space self-test only when you are ready for temporary desktop switching; it restores the original desktops and leaves management paused. Record the macOS version/build, display count, SIP state, and actual outcome. Report untested behavior as untested. See [validation history](docs/VALIDATION.md) and the [acceptance checklist](docs/ACCEPTANCE.md).

## Reporting a problem

Use the [bug report form](https://github.com/kenxcomp/yabaibye/issues/new?template=bug_report.yml). Include:

- macOS version/build and Yabaibye commit or version.
- Display count, scaling, and whether displays have separate Spaces.
- Reproduction steps, expected behavior, actual behavior, and relevant custom shortcuts.
- Which self-test passed or failed, if you ran it.

菜单中的“复制诊断信息”可提供不含窗口标题的诊断。提交前请检查内容；公开 issue 中只附相关部分，不要包含密码、签名证书、私人文档内容或不必要的屏幕截图。无需关闭 SIP 来尝试复现问题。

You do not need to run every self-test to open an issue. If an application refuses to resize, include its name/version and the approximate tile size so its minimum-size constraints can be investigated.
