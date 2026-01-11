## 中文说明（仅本 fork 修改）

这个仓库保留源仓库 MSI 方案，并新增了更推荐的“全量 MSIX”构建与安装流程。

### MSIX 构建

- 构建（并输出发布目录）：`./build-msix.ps1 -Version <版本号>`
- 输出目录默认在：`out/release/CodeModernExplorerMenu-<Version>-x64/`（也可用 `-OutputDirectory` 指定）
- 签名：
  - 使用现有 PFX：`-SigningPfxPath <path-to.pfx>`（可选 `-SigningPfxPassword` / `-SigningPublisher`）
  - 或生成自签名：`-GeneratedPfxDirectory <dir> -SigningPfxPassword <pwd>`
  - 两者都不提供时会交互提示选择

### MSIX 安装

在发布目录中直接运行：`./安装.ps1`

- 脚本会自动识别同目录唯一的 `.msix` 和 `.cer`
- 仅支持一种固定信任策略：导入到 `LocalMachine\\TrustedPublisher` + `LocalMachine\\Root`（会弹 UAC）
- 安装完成后如菜单未立刻刷新：建议重启资源管理器或注销/重新登录


***
> 以下为源仓库README原文
# Code Modern Explorer Menu
An MSI package that adds the Windows 11 Modern Explorer menu for Microsoft Visual Studio Code.
  
> [!NOTE]
> Please restart Windows Explorer after installation.
> 
> Installation requires admin rights and accepting UAC prompt to temporarily enable Developer Mode if required and restore its initial status after installation.

> [!CAUTION]
> AV may flag this as a virus due to the lack of a signature and self-elevation.

## Requirements:
- Windows 11+
- VSCode installed
- Admin rights

## Features:
- does not interfere with the classic menu
- does not interfere with the original VSCode Insiders menu
- should not interfere when VSCode stable introduces the menu
- works with both system and user installation locations
- support the case when VSCode runs as Administrator, thanks to  [ArcticLampyrid](https://github.com/microsoft/vscode-explorer-command/pull/17)
- Also works for Devices and drives, thanks to [AndromedaMelody](https://github.com/microsoft/vscode-explorer-command/pull/16)
- Future VSCode updates won’t break the menu, thanks to [huutaiii](https://github.com/huutaiii/vscode-explorer-command)

## Project changes:
- replace Azure DevOps with GitHub Actions
- removed C++ dependencies from the repository
- added vcpkg package manager
