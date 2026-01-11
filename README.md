## 中文说明（新增）

这个仓库提供两套行为：

- 旧行为（保持不变）：原始 MSI/旧系统流程（不改动原文件与逻辑）。
- 新行为（推荐）：全量 MSIX 安装流程（不依赖 ExternalLocation / sparse（稀疏包）），并提供傻瓜化安装脚本。

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
- 安装完成后如菜单未立刻刷新：重启资源管理器或重新登录

---

## 原始 README（英文，保留）

# Code Modern Explorer Menu
An MSI package that adds the Windows 11 Modern Explorer menu for Microsoft Visual Studio Code.
  
> [!NOTE]
> Please restart Windows Explorer after installation.
>
> This fork supports a signed install flow: the MSI can take one-time consent to trust the signing certificate, then installs it before installing the signed Appx. This avoids toggling Developer Mode.
>
> Important nuance: if you use a self-signed certificate, Windows Appx deployment requires the certificate to be trusted as a *machine root* (LocalMachine\Root). That requires running the installer elevated (admin). If you use a CA-trusted code signing certificate, no certificate installation should be needed.

> This repo's MSI no longer forces elevation up-front. Instead, when a self-signed cert needs to be trusted as LocalMachine\Root, the install script will trigger a single UAC prompt only for the certificate import step.

> [!IMPORTANT]
> MSI custom actions run PowerShell as hidden/non-interactive, so GUI prompts are not reliable. For one-time consent to import the signing certificate, install with `CEM_TRUST_CERT=1`:
> `msiexec /i <path-to-msi> CEM_TRUST_CERT=1`
>
> Note: if the MSI requires elevation (e.g. self-signed cert needs LocalMachine\Root), fully silent installs cannot trigger UAC. Either run without `/qn` (interactive UI can prompt for elevation), or run `msiexec` from an already-elevated terminal.

> Note: trusting a self-signed certificate into LocalMachine\Root still requires elevation. That specific step will prompt for UAC; `/qn` cannot complete it.

> [!CAUTION]
> AV may flag this as suspicious due to custom actions and self-elevation (especially with self-signed certs).

## Requirements:
- Windows 11+
- VSCode installed

## Building (signing):
- Default behavior (interactive): run `build-msi.ps1` with no args and follow the prompts to either generate a new certificate (PFX saved outside the repo) or use an existing PFX.
- Non-interactive usage (existing PFX only): provide `-SigningPfxPath <path-to.pfx>` (and optionally `-SigningPfxPassword`).

## Building (full MSIX):
- PowerShell-only (no Python/venv required): `./build-msix.ps1 -Version 4.0.1`
- To sign (recommended for install):
	- Use existing PFX: `-SigningPfxPath <path-to.pfx>` (and optionally `-SigningPfxPassword` / `-SigningPublisher`).
	- Or generate a self-signed PFX: `-GeneratedPfxDirectory <dir> -SigningPfxPassword <pwd>`.
	- If neither is provided, the script will prompt interactively.
	- If you want the full msbuild/makeappx/signtool output: add `-VerboseLog`.

## Installing (MSIX):
- Use `./install-msix.ps1` in the release folder (it auto-detects the single `.msix` and `.cer` next to the script), imports the cert trust into `LocalMachine` (UAC) and installs.
- Uninstall uses normal Appx removal (no uninstall scripts): `Get-AppxPackage -Name <IdentityName> | Remove-AppxPackage`

## Release bundle:
- `build-msix.ps1` writes a minimal end-user output folder under `out/release/<Name>-<Version>-x64/` (or `-OutputDirectory <dir>`).

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
