改了一点自用，效果如图，可以在win11右键一级菜单里使用VScode

<br>
<img width="319" height="372" alt="Image_2026-01-10_15-02-07_waxy2nub qr0" src="https://github.com/user-attachments/assets/1047404b-e3ba-4b87-b009-62593bd56cc4" />



#### 吐槽
不知道微软哪次更新把win11的win10右键中“在终端打开”给删了，现在只有win11菜单能用，调了半天都没法回来，不想回到地址栏输powershell的苦日子了，只能选择这种曲线救国方式，所幸还蛮好看的，但我估计还得适应一阵子

> [!NOTE]
> 在26年2月的某次更新后，VS Code官方已经集成了这个功能，所以本扩展可能已经失去意义。作者在忙完自己本职课业工作后可能会利用闲暇时间，基于此项目开发一个适用于所有软件添加到win11context的项目


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
