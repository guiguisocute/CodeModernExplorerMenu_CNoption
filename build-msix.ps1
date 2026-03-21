param(
    [string]$Version = '1.0.0',
    [string]$OutputDirectory = $null,

    # 启用后输出 msbuild/makeappx/signtool 的完整日志（默认仅输出关键步骤）。
    [switch]$VerboseLog,

    # 签名
    # - 若提供 SigningPfxPath：使用该 PFX 签名（签名模式选择为非交互）。
    # - 若未提供 SigningPfxPath：交互提示（使用现有 PFX / 生成 / 不签名）。
    [string]$SigningPfxPath = $null,
    # SigningPfxPassword 既支持 SecureString，也支持普通字符串（PowerShell CLI 常以字符串传入）。
    [object]$SigningPfxPassword = $null,
    [string]$SigningPublisher = $null,
    [string]$GeneratedPfxDirectory = $null,

    # 构建步骤：默认在打包前通过 msbuild 重新编译本机 DLL。
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:VerboseLogEnabled = [bool]$VerboseLog

function Write-Info {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host $Message
}

function Write-Detail {
    param([Parameter(Mandatory = $true)][string]$Message)
    if ($script:VerboseLogEnabled) {
        Write-Host $Message
    }
}

function Get-MsbuildPath {
    $cmd = Get-Command msbuild -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Path) { return $cmd.Path }
    return $null
}

function Get-GitPath {
    $cmd = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Path) { return $cmd.Path }
    return $null
}

function Get-VcpkgPath {
    # vcpkg.exe 查找顺序：
    # 1) VCPKG_ROOT（推荐）
    # 2) Visual Studio 内置 vcpkg（按用户约定的固定路径）
    # 3) PATH
    # 4) 仓库内 _deps\vcpkg（如果已存在；但不在此脚本中自动下载/bootstrap）
    if ($env:VCPKG_ROOT) {
        $p = Join-Path $env:VCPKG_ROOT 'vcpkg.exe'
        if (Test-Path -LiteralPath $p) { return $p }
    }

    $vsVcpkgRoot = 'C:\Program Files\Microsoft Visual Studio\18\Insiders\VC\vcpkg'
    $vsVcpkgExe = Join-Path $vsVcpkgRoot 'vcpkg.exe'
    if (Test-Path -LiteralPath $vsVcpkgExe) { return $vsVcpkgExe }

    $cmd = Get-Command vcpkg -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Path) { return $cmd.Path }

    $repoVcpkg = Join-Path $ScriptRoot '_deps\vcpkg\vcpkg.exe'
    if (Test-Path -LiteralPath $repoVcpkg) { return $repoVcpkg }

    return $null
}

function Ensure-VcpkgReady {
    param([Parameter(Mandatory = $true)][string]$Arch)

    $vcpkg = Get-VcpkgPath
    if ($vcpkg) { return $vcpkg }

    $vsVcpkgRoot = 'C:\Program Files\Microsoft Visual Studio\18\Insiders\VC\vcpkg'
    throw (
        "未找到 vcpkg.exe。此脚本不会自动下载/bootstrap vcpkg。" +
        "`n请确保 vcpkg 存在于以下任一位置：" +
        "`n  - 设置环境变量 VCPKG_ROOT=<vcpkg 根目录>（包含 vcpkg.exe）" +
        "`n  - Visual Studio 内置 vcpkg：$vsVcpkgRoot" +
        "`n  - 或将 vcpkg.exe 加入 PATH" +
        "`n然后重试。"
    )
}

function Ensure-VcpkgDependencies {
    param([Parameter(Mandatory = $true)][string]$Arch)

    $triplet = "$Arch-windows"
    $fmtHeader = Join-Path $ScriptRoot ("vcpkg_installed\\$triplet\\include\\fmt\\core.h")
    $wilHeader = Join-Path $ScriptRoot ("vcpkg_installed\\$triplet\\include\\wil\\resource.h")
    if ((Test-Path -LiteralPath $fmtHeader) -and (Test-Path -LiteralPath $wilHeader)) {
        return
    }

    $vcpkg = Ensure-VcpkgReady -Arch $Arch

    $maxAttempts = 3
    Push-Location $ScriptRoot
    try {
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            Write-Info "正在安装 vcpkg 依赖（$triplet）（尝试 $attempt/$maxAttempts）..."

            $out = & $vcpkg install '--triplet' $triplet '--disable-metrics' 2>&1
            $exit = $LASTEXITCODE

            if ($script:VerboseLogEnabled) {
                $out | Out-Host
            }

            if ($exit -eq 0) {
                break
            }

            $text = ($out | Out-String).TrimEnd()
            $tail = $text
            if ($tail.Length -gt 4000) { $tail = $tail.Substring($tail.Length - 4000) }

            $isFetchError = (
                $tail -match 'failed to fetch ref' -or
                $tail -match 'RPC failed' -or
                $tail -match 'Connection was reset' -or
                $tail -match 'early EOF' -or
                $tail -match 'unexpected disconnect'
            )

            if ($attempt -lt $maxAttempts -and $isFetchError) {
                Write-Info 'vcpkg 拉取注册表/端口信息失败（可能是网络波动）。稍等后自动重试...'
                Start-Sleep -Seconds (5 * $attempt)
                continue
            }

            throw ("vcpkg install 失败，退出码：{0}`n--- vcpkg 输出（末尾）---`n{1}`n`n提示：若持续出现 fetch/RPC/EOF 等错误，请检查网络/代理或稍后重试。" -f $exit, $tail)
        }
    } finally {
        Pop-Location
    }

    if (-not (Test-Path -LiteralPath $fmtHeader)) {
        throw "vcpkg 已完成，但仍未找到 fmt 头文件：$fmtHeader"
    }
}

function Test-VcxprojHasConfig {
    param(
        [Parameter(Mandatory = $true)][string]$VcxprojPath,
        [Parameter(Mandatory = $true)][string]$Configuration,
        [Parameter(Mandatory = $true)][string]$MsbuildPlatform
    )

    try {
        [xml]$xml = Get-Content -LiteralPath $VcxprojPath -Raw
        $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $ns.AddNamespace('msb', 'http://schemas.microsoft.com/developer/msbuild/2003')
        $xpath = "//msb:Project/msb:ItemGroup[@Label='ProjectConfigurations']/msb:ProjectConfiguration[@Include='$Configuration|$MsbuildPlatform']"
        $node = $xml.SelectSingleNode($xpath, $ns)
        return ($null -ne $node)
    } catch {
        return $false
    }
}

function Get-PythonPath {
    # 优先使用 Windows Python Launcher（py），其次尝试 python/python3。
    foreach ($name in @('py', 'python', 'python3')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and $cmd.Path) { return $cmd.Path }
    }
    return $null
}

function Invoke-GenerateProjectFiles {
    param([Parameter(Mandatory = $true)][string]$Arch)

    $python = Get-PythonPath
    if (-not $python) {
        throw '未找到 Python（py/python/python3）。首次运行需要用 GYP 生成 out\*.vcxproj；请安装 Python 3 后重试，或手动生成项目文件。'
    }

    $gypLibrary = Join-Path $ScriptRoot 'gyp_library.py'
    if (-not (Test-Path -LiteralPath $gypLibrary)) {
        throw "未找到 gyp_library.py：$gypLibrary"
    }

    # gyp_library.py 会临时改写 config.gypi / main.gyp 来设置架构。
    # 为了保持从 git 拉下来后工作区干净，这里备份字节并在生成结束后恢复。
    $configGypi = Join-Path $ScriptRoot 'config.gypi'
    $mainGyp = Join-Path $ScriptRoot 'main.gyp'
    $configBytes = $null
    $mainBytes = $null
    if (Test-Path -LiteralPath $configGypi) { $configBytes = [System.IO.File]::ReadAllBytes($configGypi) }
    if (Test-Path -LiteralPath $mainGyp) { $mainBytes = [System.IO.File]::ReadAllBytes($mainGyp) }

    try {
        Write-Info "正在生成本机项目文件（GYP -> out\\*.vcxproj，架构=$Arch）..."
        Push-Location $ScriptRoot
        try {
            # 不指定 msvs_version 时，GYP 可能会生成旧版 .vcproj（msbuild 无法直接用于本仓库构建）。
            # 这里根据 msbuild 路径尽量推断 VS 版本；推断失败时默认 2022。
            $msvsVersion = '2022'
            $msbuildForDetect = Get-MsbuildPath
            if ($msbuildForDetect -and $msbuildForDetect -match '\\2022\\') { $msvsVersion = '2022' }
            elseif ($msbuildForDetect -and $msbuildForDetect -match '\\2019\\') { $msvsVersion = '2019' }
            elseif ($msbuildForDetect -and $msbuildForDetect -match '\\2017\\') { $msvsVersion = '2017' }

            & $python $gypLibrary $Arch '-f' 'msvs' '-G' ("msvs_version=$msvsVersion") | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw "生成项目文件失败，退出码：$LASTEXITCODE"
            }
        } finally {
            Pop-Location
        }
    } finally {
        try {
            if ($configBytes) { [System.IO.File]::WriteAllBytes($configGypi, $configBytes) }
            if ($mainBytes) { [System.IO.File]::WriteAllBytes($mainGyp, $mainBytes) }
        } catch {
            Write-Info "警告：恢复 config.gypi/main.gyp 失败：$($_.Exception.Message)"
        }
    }
}

function Invoke-NativeBuild {
    param()

    $msbuild = Get-MsbuildPath
    if (-not $msbuild) {
        throw '未在 PATH 中找到 msbuild。请安装 Visual Studio / Build Tools，或使用 -SkipBuild 并提供已编译的 DLL。'
    }

    $projectStable = Join-Path $OutRoot 'Code Modern Explorer Menu.vcxproj'
    $projectInsiders = Join-Path $OutRoot 'Code Insiders Modern Explorer Menu.vcxproj'
    $project = if (Test-Path -LiteralPath $projectStable) { $projectStable } elseif (Test-Path -LiteralPath $projectInsiders) { $projectInsiders } else { $projectStable }

    if (-not (Test-Path -LiteralPath $project)) {
        # 从 git 拉下来后 out\ 通常为空；这里自动生成一次。
        Invoke-GenerateProjectFiles -Arch 'x64'

        $project = if (Test-Path -LiteralPath $projectStable) { $projectStable } elseif (Test-Path -LiteralPath $projectInsiders) { $projectInsiders } else { $projectStable }
        if (-not (Test-Path -LiteralPath $project)) {
            throw "未找到本机项目文件：$project（已尝试自动生成项目文件）。"
        }
    }

    $msixSource = Join-Path $ScriptRoot 'src\explorer_command_msix.cc'
    if (-not (Test-Path -LiteralPath $msixSource)) {
        throw "未找到 MSIX 专用源文件：$msixSource（请确保仓库中存在 src\\explorer_command_msix.cc）"
    }

    $originalVcxproj = $null
    $patchedVcxproj = $false
    try {
        # 为保持旧行为不变：仅在本次构建期间临时修改生成的 vcxproj，构建结束后立刻恢复。
        $originalVcxproj = Get-Content -LiteralPath $project -Raw
        $updatedVcxproj = [regex]::Replace(
            $originalVcxproj,
            '\.\.\\src\\explorer_command\.cc',
            '..\\src\\explorer_command_msix.cc'
        )

        # 兼容旧的 out\*.vcxproj：如果 include dirs 误写成 include\fmt/include\wil，会导致 #include <fmt/core.h> 解析失败。
        # 这里在构建期间做一次无侵入的临时修正（构建结束会恢复原文件）。
        $updatedVcxproj = [regex]::Replace(
            $updatedVcxproj,
            '(?i)\.\.\\vcpkg_installed\\([^\\;]+)\\include\\fmt;\.\.\\vcpkg_installed\\\1\\include\\wil;',
            '..\\vcpkg_installed\\$1\\include;'
        )
        if ($updatedVcxproj -ne $originalVcxproj) {
            Set-Content -LiteralPath $project -Value $updatedVcxproj -Encoding UTF8
            $patchedVcxproj = $true
            Write-Detail "已临时更新 vcxproj 以使用 MSIX 专用源文件：$project"
        } else {
            Write-Detail "未在 vcxproj 中找到 src\\explorer_command.cc 引用，跳过临时替换：$project"
        }

    $config = 'Default'
    $msbPlat = 'x64'

    # vcpkg 依赖：fresh clone / 清理 out、vcpkg_installed 后需要自动安装。
    Ensure-VcpkgDependencies -Arch $msbPlat
    if (-not (Test-VcxprojHasConfig -VcxprojPath $project -Configuration $config -MsbuildPlatform $msbPlat)) {
        # 有些仓库只生成 x64 项目配置；此时允许继续打包（前提是已有编译好的 DLL）。
        Write-Info "跳过本机编译：在 $project 中找不到配置 '$config|$msbPlat'"
        return
    }

    Write-Info "正在编译本机 DLL（$config|$msbPlat）..."

        if ($script:VerboseLogEnabled) {
            & $msbuild $project /t:Build /p:Configuration=$config /p:Platform=$msbPlat | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw "msbuild 失败，退出码：$LASTEXITCODE"
            }
            return
        }

        # 默认安静模式：减少控制台噪音，但保留错误信息。
        $out = & $msbuild $project /nologo /v:q /t:Build /p:Configuration=$config /p:Platform=$msbPlat 2>&1
        $exit = $LASTEXITCODE
        if ($exit -ne 0) {
            $text = ($out | Out-String).TrimEnd()
            if ($text.Length -gt 4000) { $text = $text.Substring($text.Length - 4000) }
            throw ("msbuild 失败，退出码：{0}`n--- msbuild 输出（末尾）---`n{1}" -f $exit, $text)
        }
    } finally {
        if ($patchedVcxproj -and $originalVcxproj) {
            try {
                Set-Content -LiteralPath $project -Value $originalVcxproj -Encoding UTF8
                Write-Detail "已恢复 vcxproj：$project"
            } catch {
                Write-Info "警告：恢复 vcxproj 失败：$($_.Exception.Message)"
            }
        }
    }
}

function New-EmptyDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Copy-FileVerified {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "未找到源文件：$Source"
    }

    Copy-Item -LiteralPath $Source -Destination $Destination -Force

    $srcHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    $dstHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    if ($srcHash -ne $dstHash) {
        throw "复制校验失败（SHA256 不一致）：$Source -> $Destination"
    }

    return $srcHash
}

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$OutRoot = Join-Path $ScriptRoot 'out'
if (-not (Test-Path -LiteralPath $OutRoot)) {
    New-Item -ItemType Directory -Path $OutRoot | Out-Null
}

function ConvertTo-PublisherDN {
    param([Parameter(Mandatory = $true)][string]$Publisher)
    $p = $Publisher.Trim()
    if (-not $p) { return $p }
    if ($p -match '^[A-Za-z]+\s*=') { return $p }
    return "CN=$p"
}

function ConvertFrom-SecureStringToPlainText {
    param([Parameter(Mandatory = $true)][SecureString]$SecureString)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function ConvertTo-SecureStringIfNeeded {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [SecureString]) { return $Value }

    $s = [string]$Value
    if ($s -eq $null) { return $null }
    if ($s.Length -eq 0) { return New-Object SecureString }
    return ConvertTo-SecureString -String $s -AsPlainText -Force
}

# 将密码输入（string/SecureString）统一规范为 SecureString（尽量早做，避免后续分支处理）。
$SigningPfxPassword = ConvertTo-SecureStringIfNeeded -Value $SigningPfxPassword

function Normalize-UserPathInput {
    param([Parameter(Mandatory = $true)][string]$Value)

    $v = $Value.Trim()
    if (-not $v) { return $v }

    # 处理复制/拖拽进来的路径两侧带引号的情况。
    if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) {
        $v = $v.Substring(1, $v.Length - 2)
    }

    # 展开常见环境变量（例如 %USERPROFILE%）。
    $v = [Environment]::ExpandEnvironmentVariables($v)
    return $v
}

function ConvertTo-AppxVersion {
    param([Parameter(Mandatory = $true)][string]$Version)
    $v = $Version.Trim()
    if (-not $v) { throw '版本号为空。' }
    $parts = $v.Split('.')
    if ($parts.Count -eq 4) { return $v }
    if ($parts.Count -eq 3) { return "$v.0" }
    if ($parts.Count -eq 2) { return "$v.0.0" }
    if ($parts.Count -eq 1) { return "$v.0.0.0" }
    throw "版本号格式无效：$Version"
}

function Get-MakeAppxPath {
    $cmd = Get-Command makeappx.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidate = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\App Certification Kit\makeappx.exe'
    if (Test-Path $candidate) { return $candidate }

    $binRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    if (-not (Test-Path $binRoot)) { return $null }

    $found = Get-ChildItem -Path $binRoot -Filter makeappx.exe -Recurse -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Select-Object -First 1

    if ($found) { return $found.FullName }
    return $null
}

function Get-SignToolPath {
    $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $binRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    if (-not (Test-Path $binRoot)) { return $null }

    $found = Get-ChildItem -Path $binRoot -Filter signtool.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
        Sort-Object FullName -Descending |
        Select-Object -First 1

    if ($found) { return $found.FullName }
    return $null
}

function Invoke-MakeAppx {
    param(
        [Parameter(Mandatory = $true)][string]$MakeAppxPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$WorkingDirectory = $null
    )

    $old = $null
    if ($WorkingDirectory) {
        $old = Get-Location
        Set-Location -LiteralPath $WorkingDirectory
    }

    try {
        if ($script:VerboseLogEnabled) {
            & $MakeAppxPath @Arguments
            $exitCode = $LASTEXITCODE
        } else {
            $null = & $MakeAppxPath @Arguments 2>&1
            $exitCode = $LASTEXITCODE
        }
        if ($exitCode -ne 0) {
            $quoted = ($Arguments | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } }) -join ' '
            throw "makeappx.exe 执行失败，退出码：$exitCode。命令：$MakeAppxPath $quoted"
        }
    } finally {
        if ($old) { Set-Location $old }
    }
}

function Invoke-SignTool {
    param(
        [Parameter(Mandatory = $true)][string]$SignToolPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    if ($script:VerboseLogEnabled) {
        & $SignToolPath @Arguments
        $exitCode = $LASTEXITCODE
    } else {
        $null = & $SignToolPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    if ($exitCode -ne 0) {
        $quoted = ($Arguments | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } }) -join ' '
        throw "signtool.exe 执行失败，退出码：$exitCode。命令：$SignToolPath $quoted"
    }
}

function ConvertFrom-HexColor {
    param([Parameter(Mandatory = $true)][string]$Hex)

    $h = $Hex.Trim()
    if ($h.StartsWith('#')) { $h = $h.Substring(1) }
    if ($h.Length -ne 6) { throw "颜色值无效（HEX）：$Hex" }

    $r = [Convert]::ToInt32($h.Substring(0, 2), 16)
    $g = [Convert]::ToInt32($h.Substring(2, 2), 16)
    $b = [Convert]::ToInt32($h.Substring(4, 2), 16)
    return [System.Drawing.Color]::FromArgb(255, $r, $g, $b)
}

function New-SolidPng {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$Size,
        [string]$Background = '#0078D4'
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    Add-Type -AssemblyName System.Drawing | Out-Null
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.Clear((ConvertFrom-HexColor -Hex $Background))
        } finally {
            $g.Dispose()
        }
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $bmp.Dispose()
    }
}

function New-SolidIco {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Size = 64,
        [string]$Background = '#0078D4'
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    Add-Type -AssemblyName System.Drawing | Out-Null
        if (-not ("CEM.NativeMethods" -as [type])) {
                Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CEM {
    public static class NativeMethods {
        [DllImport("user32.dll", SetLastError=true)]
        public static extern bool DestroyIcon(IntPtr hIcon);
    }
}
'@ | Out-Null
        }

    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $hIcon = [IntPtr]::Zero
    $icon = $null
    $fs = $null
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.Clear((ConvertFrom-HexColor -Hex $Background))
        } finally {
            $g.Dispose()
        }

        $hIcon = $bmp.GetHicon()
        $icon = [System.Drawing.Icon]::FromHandle($hIcon)
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $icon.Save($fs)
    } finally {
        if ($fs) { $fs.Dispose() }
        if ($icon) { $icon.Dispose() }
        if ($hIcon -ne [IntPtr]::Zero) { [void][CEM.NativeMethods]::DestroyIcon($hIcon) }
        $bmp.Dispose()
    }
}

function New-AppIconAssets {
    param(
        [Parameter(Mandatory = $true)][string]$AssetsDir
    )

    $png150 = Join-Path $AssetsDir 'code_150x150.png'
    $png44 = Join-Path $AssetsDir 'code_44x44.png'
    $png70 = Join-Path $AssetsDir 'code_70x70.png'
    $ico = Join-Path $AssetsDir 'code.ico'

    function Get-VSCodeExeCandidates {
        param([ValidateSet('stable', 'insiders')][string]$V)
        $cands = @()
        if ($V -eq 'insiders') {
            $cands += @(
                "$env:LOCALAPPDATA\Programs\Microsoft VS Code Insiders\Code - Insiders.exe",
                "$env:ProgramFiles\Microsoft VS Code Insiders\Code - Insiders.exe",
                "$env:ProgramFiles(x86)\Microsoft VS Code Insiders\Code - Insiders.exe"
            )
        } else {
            $cands += @(
                "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe",
                "$env:ProgramFiles\Microsoft VS Code\Code.exe",
                "$env:ProgramFiles(x86)\Microsoft VS Code\Code.exe"
            )
        }

        # 尝试从 PATH（例如 bin\code.cmd）定位，再反推真实 EXE 路径。
        $cmdName = if ($V -eq 'insiders') { 'code-insiders' } else { 'code' }
        try {
            $cmd = Get-Command $cmdName -ErrorAction Stop | Select-Object -First 1
            if ($cmd -and $cmd.Path) {
                $p = $cmd.Path
                if ($p -match '\.cmd$') {
                    $binDir = Split-Path -Parent $p
                    $exeName = if ($V -eq 'insiders') { 'Code - Insiders.exe' } else { 'Code.exe' }
                    $resolved = Join-Path (Join-Path $binDir '..\..') $exeName
                    $cands += $resolved
                } else {
                    $cands += $p
                }
            }
        } catch {
            # 忽略
        }

        return $cands
    }

    function Try-WriteAssetsFromExeIcon {
        param([Parameter(Mandatory = $true)][string]$ExePath)

        Add-Type -AssemblyName System.Drawing | Out-Null
        try {
            $extracted = [System.Drawing.Icon]::ExtractAssociatedIcon($ExePath)
            if (-not $extracted) { return $false }

            # 保存 ICO
            $fs = [System.IO.File]::Open($ico, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
            try {
                $extracted.Save($fs)
            } finally {
                $fs.Dispose()
            }

            $bmp = $extracted.ToBitmap()
            try {
                function Save-ResizedPng {
                    param([int]$Size, [string]$Path)

                    $dst = New-Object System.Drawing.Bitmap $Size, $Size
                    try {
                        $g = [System.Drawing.Graphics]::FromImage($dst)
                        try {
                            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                            $g.Clear([System.Drawing.Color]::Transparent)
                            $g.DrawImage($bmp, 0, 0, $Size, $Size)
                        } finally {
                            $g.Dispose()
                        }
                        $dst.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
                    } finally {
                        $dst.Dispose()
                    }
                }

                Save-ResizedPng -Size 150 -Path $png150
                Save-ResizedPng -Size 44 -Path $png44
                Save-ResizedPng -Size 70 -Path $png70
            } finally {
                $bmp.Dispose()
            }

            $extracted.Dispose()
            return $true
        } catch {
            return $false
        }
    }

    function Try-WriteAssetsFromVsCodeResources {
        param([Parameter(Mandatory = $true)][string]$ExePath)

        try {
            $exeDir = Split-Path -Parent $ExePath
            $srcIco = Join-Path $exeDir 'resources\app\resources\win32\code.ico'
            if (-not (Test-Path -LiteralPath $srcIco)) { return $false }

            Copy-Item -LiteralPath $srcIco -Destination $ico -Force

            Add-Type -AssemblyName System.Drawing | Out-Null
            $iconObj = New-Object System.Drawing.Icon($srcIco)
            try {
                $bmp = $iconObj.ToBitmap()
                try {
                    function Save-ResizedPng {
                        param([int]$Size, [string]$Path)

                        $dst = New-Object System.Drawing.Bitmap $Size, $Size
                        try {
                            $g = [System.Drawing.Graphics]::FromImage($dst)
                            try {
                                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                                $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                                $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                                $g.Clear([System.Drawing.Color]::Transparent)
                                $g.DrawImage($bmp, 0, 0, $Size, $Size)
                            } finally {
                                $g.Dispose()
                            }
                            $dst.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
                        } finally {
                            $dst.Dispose()
                        }
                    }

                    Save-ResizedPng -Size 150 -Path $png150
                    Save-ResizedPng -Size 44 -Path $png44
                    Save-ResizedPng -Size 70 -Path $png70
                } finally {
                    $bmp.Dispose()
                }
            } finally {
                $iconObj.Dispose()
            }

            return $true
        } catch {
            return $false
        }
    }

    $tryOrder = @('stable', 'insiders')

    $exe = $null
    foreach ($v in $tryOrder) {
        $exe = (Get-VSCodeExeCandidates -V $v) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
        if ($exe) { break }
    }
    $ok = $false
    if ($exe) {
        # 优先使用 VS Code 自带的高质量 ICO（如果可用）。
        $ok = Try-WriteAssetsFromVsCodeResources -ExePath $exe
        if (-not $ok) {
            $ok = Try-WriteAssetsFromExeIcon -ExePath $exe
        }
        if ($script:VerboseLogEnabled) {
            if ($ok) {
                Write-Detail "图标来源：$exe"
            } else {
                Write-Detail "图标来源：回退（无法从 $exe 提取图标）"
            }
        }
    } elseif ($script:VerboseLogEnabled) {
        Write-Detail '图标来源：回退（在常见位置未找到 VS Code 可执行文件）'
    }

    if (-not $ok) {
        # 兜底：生成确定性的占位图标。
        New-SolidPng -Path $png150 -Size 150
        New-SolidPng -Path $png44 -Size 44
        New-SolidPng -Path $png70 -Size 70
        New-SolidIco -Path $ico -Size 64
    }
}

function New-StubExeIfMissing {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    # 始终覆盖：这样我们可以迭代启动器实现而无需用户手工清理旧文件。

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

        $source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;

internal static class Program {
    private static string Expand(string s) {
        if (string.IsNullOrEmpty(s)) return s;
        return Environment.ExpandEnvironmentVariables(s);
    }

    private static string Quote(string arg) {
        if (arg == null) return "\"\"";
        if (arg.Length == 0) return "\"\"";
        if (arg.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return arg;
        return "\"" + arg.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
    }

    private static IEnumerable<string> CandidatePaths() {
        // Prefer stable if present
        yield return Expand("%LocalAppData%\\Programs\\Microsoft VS Code\\Code.exe");
        yield return Expand("%ProgramFiles%\\Microsoft VS Code\\Code.exe");
        yield return Expand("%ProgramFiles(x86)%\\Microsoft VS Code\\Code.exe");

        // Fallback to Insiders
        yield return Expand("%LocalAppData%\\Programs\\Microsoft VS Code Insiders\\Code - Insiders.exe");
        yield return Expand("%ProgramFiles%\\Microsoft VS Code Insiders\\Code - Insiders.exe");
        yield return Expand("%ProgramFiles(x86)%\\Microsoft VS Code Insiders\\Code - Insiders.exe");
    }

    private static string FindExe() {
        foreach (var p in CandidatePaths()) {
            if (!string.IsNullOrEmpty(p) && File.Exists(p)) return p;
        }
        // Fallback: try PATH shims
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in path.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries)) {
            try {
                var cand = Path.Combine(dir.Trim(), "code.cmd");
                if (File.Exists(cand)) return cand;
                cand = Path.Combine(dir.Trim(), "code.exe");
                if (File.Exists(cand)) return cand;
                cand = Path.Combine(dir.Trim(), "code-insiders.cmd");
                if (File.Exists(cand)) return cand;
                cand = Path.Combine(dir.Trim(), "code-insiders.exe");
                if (File.Exists(cand)) return cand;
            } catch { }
        }
        return null;
    }

    public static int Main(string[] args) {
        var exe = FindExe();
        if (string.IsNullOrEmpty(exe)) return 2;

        var argv = new List<string>();
        argv.Add("--new-window");
        if (args != null) {
            foreach (var a in args) {
                if (string.IsNullOrEmpty(a)) continue;
                argv.Add(Quote(a));
            }
        }

        var psi = new ProcessStartInfo();

        // If PATH hit a .cmd, execute via cmd.exe.
        if (exe.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase)) {
            psi.FileName = "cmd.exe";
            psi.Arguments = "/c " + Quote(exe) + " " + string.Join(" ", argv);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
        } else {
            psi.FileName = exe;
            psi.Arguments = string.Join(" ", argv);
            psi.UseShellExecute = false;
        }

        Process.Start(psi);
        return 0;
    }
}
'@

    try {
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        }
        # 构建为 GUI（Windows 子系统）应用，避免 Explorer 调用时闪出控制台窗口。
        Add-Type -TypeDefinition $source -Language CSharp -OutputAssembly $Path -OutputType WindowsApplication -WarningAction SilentlyContinue
    } catch {
        throw "通过 Add-Type 构建启动器 EXE 失败。请安装带 C# 编译器支持的 .NET 运行时，或提供预编译的 CEMHost.exe。错误：$($_.Exception.Message)"
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "启动器 EXE 未生成：$Path"
    }
}

function New-FullPackageDir {
    param(
        [Parameter(Mandatory = $true)][string]$Publisher,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $pkgDir = Join-Path $OutRoot 'explorer_pkg_x64'
    if (-not (Test-Path -LiteralPath $pkgDir)) {
        New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
    }

    $templateMsix = Join-Path $ScriptRoot 'template\AppxManifest.msix.xml'
    $templateLegacy = Join-Path $ScriptRoot 'template\AppxManifest.xml'
    $template = if (Test-Path -LiteralPath $templateMsix) { $templateMsix } else { $templateLegacy }
    if (-not (Test-Path -LiteralPath $template)) {
        throw "未找到模板清单文件：$templateMsix / $templateLegacy"
    }

    $content = Get-Content -LiteralPath $template -Raw

    $content = $content.Replace('@@PublisherDisplayName@@', 'Code Modern Explorer Menu')

    # 单一包标识（仅 x64），同时兼容 VS Code 稳定版与预览版（Insiders）。
    $content = $content.Replace('@@Publisher@@', 'Code.Modern.Explorer.Menu')
    $content = $content.Replace('@@PackageDescription@@', 'Code Modern Explorer Menu')
    $content = $content.Replace('@@PackageName@@', 'Code.Modern.Explorer.Menu')
    $content = $content.Replace('@@PackageDisplayName@@', 'Code Modern Explorer Menu')
    $content = $content.Replace('@@Application@@', 'CEMHost.exe')
    $content = $content.Replace('@@ApplicationIdShort@@', 'Code')
    $content = $content.Replace('@@MenuID@@', 'OpenWithCode')
    $content = $content.Replace('@@CLSID@@', 'E4E4C322-3388-45AF-8D39-BE19BFC78A18')
    $content = $content.Replace('@@PackageDLL@@', 'Code Modern Explorer Menu.dll')
    $dllName = 'Code Modern Explorer Menu.dll'

    # 填充真实 Publisher DN 与 Identity 版本号。
    $identityVersion = ConvertTo-AppxVersion -Version $Version
    # 重要：避免误匹配 MinVersion="..."（其中包含子串 Version="..."）。
    # 使用 MatchEvaluator，避免替换时将 "$1" + 版本号误解析成 "$14"。
    $content = [regex]::Replace(
        $content,
        '(<Identity[^>]*\sPublisher=")[^"]+(")',
        { param($m) $m.Groups[1].Value + $Publisher + $m.Groups[2].Value }
    )
    $content = [regex]::Replace(
        $content,
        '(<Identity[^>]*\sVersion=")[^"]+(")',
        { param($m) $m.Groups[1].Value + $identityVersion + $m.Groups[2].Value }
    )

    $manifestPath = Join-Path $pkgDir 'AppxManifest.xml'
    Set-Content -LiteralPath $manifestPath -Value $content -Encoding UTF8

    # 必需的 Logo 与菜单图标（始终覆盖）
    $assetsDir = Join-Path $pkgDir 'resources\app\resources\win32'
    New-AppIconAssets -AssetsDir $assetsDir

    # Host EXE（始终覆盖）
    New-StubExeIfMissing -Path (Join-Path $pkgDir 'CEMHost.exe')

    # DLL（支持常见输出目录布局，例如生成的 vcxproj 输出到 out\Default\）
    $srcDllCandidates = @(
        (Join-Path $OutRoot $dllName),
        (Join-Path (Join-Path $OutRoot 'Default') $dllName),
        (Join-Path (Join-Path $OutRoot 'Release') $dllName),
        (Join-Path (Join-Path $OutRoot 'x64') $dllName)
    )

    $srcDll = $srcDllCandidates |
        Where-Object { Test-Path -LiteralPath $_ } |
        ForEach-Object {
            $i = Get-Item -LiteralPath $_
            [pscustomobject]@{ Path = $_; LastWriteTimeUtc = $i.LastWriteTimeUtc }
        } |
        Sort-Object -Property LastWriteTimeUtc -Descending |
        Select-Object -First 1 |
        ForEach-Object { $_.Path }

    if ($srcDll) {
        Write-Detail "使用 DLL：$srcDll"
    }
    $dstDll = Join-Path $pkgDir $dllName
    if (-not $srcDll) {
        $cands = ($srcDllCandidates -join "`n - ")
        throw "未找到预期的 DLL。请先编译项目，确保 DLL 存在于以下路径之一：`n - $cands"
    }
    Copy-Item -LiteralPath $srcDll -Destination $dstDll -Force

    return [pscustomobject]@{
        PackageDir = $pkgDir
        ManifestPath = $manifestPath
        DllName = $dllName
        Publisher = $Publisher
        IdentityVersion = $identityVersion
    }
}

function Get-SigningMaterial {
    param(
        [Parameter(Mandatory = $true)][string]$SigningMode,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Publisher = $null
    )

    if ($SigningMode -eq 'Off') {
        return $null
    }

    $signDir = Join-Path $OutRoot 'signing'
    if (-not (Test-Path -LiteralPath $signDir)) {
        New-Item -ItemType Directory -Path $signDir -Force | Out-Null
    }

    if ($SigningMode -eq 'UseExisting') {
        if (-not $SigningPfxPath) {
            $SigningPfxPath = Read-Host '请输入 PFX 路径（建议放在仓库之外）'
        }

        $SigningPfxPath = Normalize-UserPathInput -Value ([string]$SigningPfxPath)

        $pfxPath = (Resolve-Path -LiteralPath $SigningPfxPath).Path

        if (-not $SigningPfxPassword) {
            $SigningPfxPassword = Read-Host -AsSecureString '请输入 PFX 密码（不会回显）'
        }

        $cert = $null
        try {
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
                $pfxPath,
                $SigningPfxPassword,
                ([System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet)
            )
        } catch {
            throw "从 PFX 加载签名证书失败。$($_.Exception.Message)"
        }

        if (-not $cert -or -not $cert.Subject) {
            throw '签名证书的 Subject 为空。'
        }

        if ($Publisher -and ($cert.Subject -ne $Publisher)) {
            throw "签名证书的 Subject 与 Publisher 不匹配。期望 '$Publisher'，实际 '$($cert.Subject)'。"
        }

        $cerPath = Join-Path $signDir 'SigningCertificate.cer'
        try {
            [System.IO.File]::WriteAllBytes(
                $cerPath,
                $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
            )
        } catch {
            throw "导出 CER 失败：$cerPath。$($_.Exception.Message)"
        }

        return [pscustomobject]@{
            PfxPath = $pfxPath
            PfxPassword = $SigningPfxPassword
            CerPath = $cerPath
            Publisher = $cert.Subject
        }
    }

    if ($SigningMode -eq 'Generate') {
        if (-not $GeneratedPfxDirectory) {
            $GeneratedPfxDirectory = Read-Host '请输入用于保存生成的 PFX 的目录（建议放在仓库之外）'
        }
        $GeneratedPfxDirectory = Normalize-UserPathInput -Value ([string]$GeneratedPfxDirectory)
        if (-not (Test-Path -LiteralPath $GeneratedPfxDirectory)) {
            try {
                New-Item -ItemType Directory -Path $GeneratedPfxDirectory -Force | Out-Null
            } catch {
                throw "创建用于保存生成 PFX 的目录失败：$GeneratedPfxDirectory。$($_.Exception.Message)"
            }
        }
        $materialDir = (Resolve-Path -LiteralPath $GeneratedPfxDirectory).Path

        if (-not $SigningPfxPassword) {
            $SigningPfxPassword = Read-Host -AsSecureString '请输入新生成 PFX 的密码（不会回显）'
        }

        $pfxPath = Join-Path $materialDir 'SigningCertificate.pfx'
        $cerPath = Join-Path $OutRoot 'signing\SigningCertificate.cer'

        $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $Publisher -CertStoreLocation 'Cert:\CurrentUser\My'
        Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $SigningPfxPassword -Force | Out-Null
        Export-Certificate -Cert $cert -FilePath $cerPath -Force | Out-Null

        return [pscustomobject]@{
            PfxPath = $pfxPath
            PfxPassword = $SigningPfxPassword
            CerPath = $cerPath
            Publisher = $Publisher
        }
    }

    throw "无效的 SigningMode：$SigningMode"
}

# 确定签名模式：若指定 SigningPfxPath 则为非交互；否则交互提示。
$SigningMode = $null
if ($SigningPfxPath) {
    $SigningMode = 'UseExisting'
} elseif ($GeneratedPfxDirectory) {
    $SigningMode = 'Generate'
} else {
    Write-Host '签名模式：'
    Write-Host '  1) 使用现有 PFX（推荐：用于正式发布/持续集成）'
    Write-Host '  2) 生成自签名 PFX（测试用途）'
    Write-Host '  3) 不签名（仅用于本地调试，不推荐）'
    $choice = (Read-Host '请选择（1/2/3）').Trim()
    if ($choice -eq '1') { $SigningMode = 'UseExisting' }
    elseif ($choice -eq '2') { $SigningMode = 'Generate' }
    elseif ($choice -eq '3') { $SigningMode = 'Off' }
    else { throw "无效选择：$choice" }
}

# 确定 Publisher DN。
if ($SigningMode -eq 'UseExisting') {
    # 若用户未显式提供 Publisher，则从 PFX 的 Subject 推导。
    if (-not $SigningPublisher) {
        $material = Get-SigningMaterial -SigningMode 'UseExisting'
        $SigningPublisher = $material.Publisher
    } else {
        $SigningPublisher = ConvertTo-PublisherDN -Publisher $SigningPublisher
        $material = Get-SigningMaterial -SigningMode 'UseExisting' -Publisher $SigningPublisher
    }
} elseif ($SigningMode -eq 'Generate') {
    if (-not $SigningPublisher) {
        $SigningPublisher = 'CN=Code.Modern.Explorer.Menu, O=Code.Modern.Explorer.Menu, L=Code.Modern.Explorer.Menu, S=Code.Modern.Explorer.Menu, C=PL'
    }
    $SigningPublisher = ConvertTo-PublisherDN -Publisher $SigningPublisher
    $material = Get-SigningMaterial -SigningMode 'Generate' -Publisher $SigningPublisher
} else {
    # 关闭签名：manifest 仍需要 Identity Publisher；沿用历史默认值。
    if (-not $SigningPublisher) {
        $SigningPublisher = 'CN=Code.Modern.Explorer.Menu, O=Code.Modern.Explorer.Menu, L=Code.Modern.Explorer.Menu, S=Code.Modern.Explorer.Menu, C=PL'
    }
    $SigningPublisher = ConvertTo-PublisherDN -Publisher $SigningPublisher
    $material = $null
}

if (-not $SkipBuild) {
    Invoke-NativeBuild
}

$pkg = New-FullPackageDir -Publisher $SigningPublisher -Version $Version

$makeappx = Get-MakeAppxPath
if (-not $makeappx) {
    throw '未找到 makeappx.exe。请安装 Windows 10/11 SDK（App Certification Kit），或将 makeappx 加入 PATH。'
}

${finalOutputDirectory} = $OutputDirectory
if (-not ${finalOutputDirectory}) {
    # CodeModernExplorerMenu 是项目名称，不做翻译。
    $releaseName = 'CodeModernExplorerMenu'
    ${finalOutputDirectory} = Join-Path (Join-Path $OutRoot 'release') ("{0}-{1}-x64" -f $releaseName, $Version)
}

# 注意：signtool/makeappx 在某些环境下对中文路径/文件名兼容性不佳。
# 为了避免签名阶段出现“File not found”（实际是路径编码问题），这里使用纯 ASCII 的 staging 目录/文件名进行打包与签名，
# 然后再将最终 MSIX 复制到终端用户输出目录，并使用中文文件名。
$stagingRoot = Join-Path $OutRoot 'staging'
if (-not (Test-Path -LiteralPath $stagingRoot)) {
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
}
$stagingOutputDirectory = Join-Path $stagingRoot ("msix-{0}-x64" -f $Version)
if (-not (Test-Path -LiteralPath $stagingOutputDirectory)) {
    New-Item -ItemType Directory -Path $stagingOutputDirectory -Force | Out-Null
}

if (-not (Test-Path -LiteralPath ${finalOutputDirectory})) {
    New-Item -ItemType Directory -Path ${finalOutputDirectory} -Force | Out-Null
}

$displayName = 'Code Modern Explorer Menu'
$msixFileNameUser = ("CodeModernExplorerMenu-{0}-x64.msix" -f $Version)
$msixFileNameStaging = ("CodeModernExplorerMenu-{0}-x64.msix" -f $Version)
$msixPathStaging = Join-Path $stagingOutputDirectory $msixFileNameStaging
$msixPathUser = Join-Path ${finalOutputDirectory} $msixFileNameUser

Invoke-MakeAppx -MakeAppxPath $makeappx -WorkingDirectory $OutRoot -Arguments @(
    'pack',
    '/d', (Split-Path -Leaf $pkg.PackageDir),
    '/p', $msixPathStaging,
    '/o',
    '/nv'
)
if ($material) {
    $signtool = Get-SignToolPath
    if (-not $signtool) {
        throw '未找到 signtool.exe。请安装 Windows 10/11 SDK，或将 signtool 加入 PATH。'
    }

    $plainPassword = ConvertFrom-SecureStringToPlainText -SecureString $material.PfxPassword

    Invoke-SignTool -SignToolPath $signtool -Arguments @(
        'sign',
        '/fd', 'SHA256',
        '/f', $material.PfxPath,
        '/p', $plainPassword,
        $msixPathStaging
    )

    Write-Detail "已签名（staging）MSIX：$msixPathStaging"
    Write-Detail "证书（CER）：$($material.CerPath)"
} else {
    Write-Detail "已生成未签名（staging）MSIX：$msixPathStaging"
}

# 将最终 MSIX 放入终端用户输出目录。
Copy-Item -LiteralPath $msixPathStaging -Destination $msixPathUser -Force
Remove-Item -LiteralPath $msixPathStaging -Force -ErrorAction SilentlyContinue

if ($material) {
    Write-Info "已生成并签名 MSIX：$msixPathUser"
} else {
    Write-Info "已生成未签名 MSIX：$msixPathUser"
}

Write-Detail "打包目录：$($pkg.PackageDir)"
Write-Detail "清单：$($pkg.ManifestPath)"

# 终端用户输出：始终将安装脚本 +（可选）CER 同步到 OutputDirectory。
$installScriptName = '安装.ps1'
$installOut = Join-Path ${finalOutputDirectory} $installScriptName
$installSource = Join-Path $ScriptRoot 'install-msix.ps1'
$installHash = Copy-FileVerified -Source $installSource -Destination $installOut
$installStamp = (Get-Item -LiteralPath $installSource).LastWriteTime
Write-Detail "已将 ${installScriptName} 从 install-msix.ps1 同步到输出目录（最后修改时间=$installStamp，SHA256=$installHash）"

$outCer = $null
if ($material -and $material.CerPath -and (Test-Path -LiteralPath $material.CerPath)) {
    $outCer = Join-Path ${finalOutputDirectory} '签名证书.cer'
    Copy-Item -LiteralPath $material.CerPath -Destination $outCer -Force
}

$identityName = 'Code.Modern.Explorer.Menu'

$installTxt = @()
$installTxt += "CodeModernExplorerMenu（MSIX）"
$installTxt += "版本：$Version"
$installTxt += '平台：x64'
$installTxt += ''
$installTxt += '安装：'
$installTxt += "  方式 A：右键 ${installScriptName} -> 使用 PowerShell 运行"
$installTxt += "  方式 B：在此目录打开 PowerShell，然后运行：.\\${installScriptName}"
$installTxt += ''
if ($outCer) {
    $installTxt += '证书：'
    $installTxt += '  - 此目录包含 签名证书.cer。'
    $installTxt += "  - ${installScriptName} 会自动导入证书信任（仅导入 LocalMachine\\TrustedPublisher + LocalMachine\\Root，需要 UAC）。"
    $installTxt += ''
} else {
    $installTxt += '证书：'
    $installTxt += '  - 警告：未找到 签名证书.cer。若 MSIX 使用自签名证书签名，安装将失败。'
    $installTxt += ''
}
$installTxt += '卸载（不需要脚本）：'
$installTxt += '  - 设置 -> 应用 -> 已安装的应用 -> 卸载'
$installTxt += "  - 或 PowerShell：Get-AppxPackage -Name $identityName | Remove-AppxPackage"
$installTxt += ''
$installTxt += '备注：'
$installTxt += '  - 安装/卸载后如右键菜单未刷新，请重启 Windows 资源管理器（或注销/重新登录）。'

Set-Content -LiteralPath (Join-Path ${finalOutputDirectory} '安装说明.txt') -Value $installTxt -Encoding UTF8

Write-Info "输出目录：${finalOutputDirectory}"
