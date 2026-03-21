param(
    # 输出更详细的日志（默认仅输出关键步骤）。
    [switch]$VerboseLog
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

$script:ExpectedIdentityName = 'Code.Modern.Explorer.Menu'

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Stop-ProcessesUsingModule {
    param([Parameter(Mandatory = $true)][string]$ModuleName)

    # 使用 tasklist /m 查找加载了指定模块的进程 PID，然后逐个结束。
    # 这比直接杀掉所有 dllhost.exe 更精准。
    try {
        $output = & tasklist /m $ModuleName /fo csv 2>$null
        if (-not $output) { return }

        $rows = $output | ConvertFrom-Csv
        foreach ($row in $rows) {
            $pid = $null
            try { $pid = [int]$row.PID } catch { $pid = $null }
            if (-not $pid -or $pid -le 0) { continue }

            try {
                $p = Get-Process -Id $pid -ErrorAction Stop
                Write-Detail "正在结束占用 ${ModuleName} 的进程：$($p.ProcessName)（PID $pid）"
                Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
            } catch {
                # 尽力而为：忽略无法结束的进程。
            }
        }
    } catch {
        # 尽力而为：忽略解析/查询失败。
    }
}

function Restart-WindowsExplorer {
    try {
        Write-Detail '正在关闭 Windows 资源管理器...'
        Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
        Write-Detail '正在启动 Windows 资源管理器...'
        Start-Process explorer.exe | Out-Null
        Start-Sleep -Milliseconds 600
    } catch {
        Write-Detail "自动重启资源管理器失败：$($_.Exception.Message)"
    }
}

function Stop-WindowsExplorer {
    try {
        Write-Detail '正在关闭 Windows 资源管理器...'
        Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
    } catch {
        Write-Detail "关闭资源管理器失败：$($_.Exception.Message)"
    }
}

function Start-WindowsExplorer {
    try {
        Write-Detail '正在启动 Windows 资源管理器...'
        Start-Process explorer.exe | Out-Null
        Start-Sleep -Milliseconds 600
    } catch {
        Write-Detail "启动资源管理器失败：$($_.Exception.Message)"
    }
}

function Remove-AppxPackageWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$PackageFullName,
        [int]$TimeoutSeconds = 30
    )

    $job = Start-Job -ScriptBlock {
        param($pfn)
        $ErrorActionPreference = 'Stop'
        Remove-AppxPackage -Package $pfn -ErrorAction Stop
    } -ArgumentList $PackageFullName

    if (-not (Wait-Job -Job $job -Timeout $TimeoutSeconds)) {
        try { Stop-Job -Job $job -Force | Out-Null } catch { }
        try { Remove-Job -Job $job -Force | Out-Null } catch { }
        throw "Remove-AppxPackage 超时（${TimeoutSeconds}s）：$PackageFullName"
    }

    try {
        Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
    } finally {
        try { Remove-Job -Job $job -Force | Out-Null } catch { }
    }
}

function Invoke-Elevated {
    param(
        [Parameter(Mandatory = $true)][string[]]$ArgumentList
    )

    $exe = 'powershell.exe'

    function Quote-ArgForWinCommandLine {
        param([Parameter(Mandatory = $true)][string]$Value)
        # 引号规则保持“保守 + 稳健”：
        # 我们只需要支持路径（可能含空格）和 base64 字符串（不含空格）。
        if ($Value -match '"') {
            throw "不支持包含双引号的参数：$Value"
        }
        if ($Value -match '\s') {
            return '"' + $Value + '"'
        }
        return $Value
    }

    # 在 Windows PowerShell 5.1 中，Start-Process -Verb RunAs 使用 ShellExecute，实质上需要传入单个命令行字符串。
    # 这里用保守的规则把各参数片段拼成一条命令行。
    $tokens = @($ArgumentList)
    $argString = ($tokens | ForEach-Object { Quote-ArgForWinCommandLine -Value ([string]$_) }) -join ' '

    Write-Info '正在执行需要管理员权限的步骤（将弹出 UAC 提示）...'
    try {
        # 注意：在 Windows PowerShell 5.1 中，-Verb RunAs 走 ShellExecute，不能可靠地配合重定向参数使用。
        $p = Start-Process -FilePath $exe -ArgumentList $argString -Verb RunAs -Wait -PassThru
    } catch {
        # 用户取消 UAC（ERROR_CANCELLED = 1223）。注意并非所有异常类型都暴露 NativeErrorCode。
        $ex = $_.Exception
        $native = $null
        if ($ex -is [System.ComponentModel.Win32Exception]) {
            $native = $ex.NativeErrorCode
        } elseif ($ex -and $ex.PSObject -and ($ex.PSObject.Properties.Match('NativeErrorCode').Count -gt 0)) {
            $native = $ex.NativeErrorCode
        }
        if ($native -eq 1223) {
            throw '已取消 UAC，无法将证书导入到 LocalMachine 存储。'
        }
        throw
    }

    if (-not $p) {
        throw '无法启动提升权限的 PowerShell。'
    }

    if ($p.ExitCode -ne 0) {
        $i64 = [int64]$p.ExitCode
        $u64 = if ($i64 -lt 0) { [uint64]($i64 + 0x100000000) } else { [uint64]$i64 }
        $hex = ('0x{0:X8}' -f $u64)
        throw "提权步骤失败，退出码：$($p.ExitCode)（$hex）。"
    }
}

function Import-CertificateLocalMachineTrusted {
    param([Parameter(Mandatory = $true)][string]$CerPath)

    # 始终仅导入到 LocalMachine\TrustedPublisher + LocalMachine\Root（这是唯一支持的模式）。
    $cerResolved = (Resolve-Path -LiteralPath $CerPath).Path
    $thumb = (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($cerResolved)).Thumbprint

    if (-not (Test-IsAdministrator)) {
        Write-Info '正在导入证书信任到 LocalMachine（需要管理员权限，将弹出 UAC）...'
        $helperPath = Join-Path $env:TEMP ("cem-import-cert-" + [Guid]::NewGuid().ToString('N') + '.ps1')
        $logPath = Join-Path $env:TEMP ("cem-import-cert-" + [Guid]::NewGuid().ToString('N') + '.log')

        $cerB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cerResolved))
        $logB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($logPath))

        $helper = @'
param(
    [Parameter(Mandatory = $true)][string]$CerPathB64,
    [Parameter(Mandatory = $true)][string]$LogPathB64
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Decode-B64Utf8 {
    param([Parameter(Mandatory = $true)][string]$B64)
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($B64))
}

function Add-CertIfMissing {
    param(
        [Parameter(Mandatory = $true)][string]$Cer,
        [Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.StoreLocation]$Loc,
        [Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.StoreName]$Name
    )

    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Cer)
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($Name, $Loc)
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try {
        $existing = $store.Certificates.Find(
            [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
            $cert.Thumbprint,
            $false
        )
        if ($existing.Count -gt 0) { return $false }
        $store.Add($cert)
        return $true
    } finally {
        $store.Close()
    }
}

$cerPath = (Resolve-Path -LiteralPath (Decode-B64Utf8 -B64 $CerPathB64)).Path
$logPath = Decode-B64Utf8 -B64 $LogPathB64

try {
    $addedTP = Add-CertIfMissing -Cer $cerPath -Loc ([System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine) -Name ([System.Security.Cryptography.X509Certificates.StoreName]::TrustedPublisher)
    $addedRoot = Add-CertIfMissing -Cer $cerPath -Loc ([System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine) -Name ([System.Security.Cryptography.X509Certificates.StoreName]::Root)

    $thumb = (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($cerPath)).Thumbprint
    $msg = "OK: Imported/verified certificate. Thumbprint=$thumb AddedTrustedPublisher=$addedTP AddedRoot=$addedRoot"
    [IO.File]::WriteAllText($logPath, $msg, [Text.Encoding]::UTF8)
    exit 0
} catch {
    $e = $_
    $details = @(
        "FAILED",
        ("Message: {0}" -f $e.Exception.Message),
        ("Type: {0}" -f $e.Exception.GetType().FullName),
        ("ScriptStackTrace: {0}" -f $e.ScriptStackTrace)
    ) -join [Environment]::NewLine
    try { [IO.File]::WriteAllText($logPath, $details, [Text.Encoding]::UTF8) } catch { }
    exit 1
}
'@

        try {
            Set-Content -LiteralPath $helperPath -Value $helper -Encoding UTF8 -Force
            $argList = @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', $helperPath,
                '-CerPathB64', $cerB64,
                '-LogPathB64', $logB64
            )
            Invoke-Elevated -ArgumentList $argList
        } finally {
            try { Remove-Item -LiteralPath $helperPath -Force -ErrorAction SilentlyContinue } catch { }
        }

        if (Test-Path -LiteralPath $logPath) {
            $elevatedLog = Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue
            if ($elevatedLog) {
                Write-Detail ("提权导证书日志：{0}" -f $elevatedLog.Trim())
            }
            try { Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue } catch { }
        }
        return
    }

    # 已在管理员权限下：直接在当前进程执行导入。
    function Add-CertIfMissing {
        param(
            [Parameter(Mandatory = $true)][string]$Cer,
            [Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.StoreLocation]$Loc,
            [Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.StoreName]$Name
        )

        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Cer)
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($Name, $Loc)
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        try {
            $existing = $store.Certificates.Find(
                [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
                $cert.Thumbprint,
                $false
            )
            if ($existing.Count -gt 0) { return }
            $store.Add($cert)
        } finally {
            $store.Close()
        }
    }

    Add-CertIfMissing -Cer $cerResolved -Loc ([System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine) -Name ([System.Security.Cryptography.X509Certificates.StoreName]::TrustedPublisher)
    Add-CertIfMissing -Cer $cerResolved -Loc ([System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine) -Name ([System.Security.Cryptography.X509Certificates.StoreName]::Root)
    Write-Detail "已确认/导入证书到 LocalMachine\\TrustedPublisher + LocalMachine\\Root（Thumbprint=$thumb）"
}

function Import-CertificateToStore {
    param(
        [Parameter(Mandatory = $true)][string]$CerPath,
        [Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.StoreLocation]$StoreLocation,
        [Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.StoreName]$StoreName
    )

    if (-not (Test-Path -LiteralPath $CerPath)) {
        throw "未找到 CER：$CerPath"
    }

    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CerPath)

    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($StoreName, $StoreLocation)
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try {
        $existing = $store.Certificates.Find(
            [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
            $cert.Thumbprint,
            $false
        )
        if ($existing.Count -gt 0) {
            Write-Detail "证书已存在于 $StoreLocation\\${StoreName}：$($cert.Subject)（$($cert.Thumbprint)）"
            Write-Log ("Certificate already present in {0}\\{1}: {2} ({3})" -f $StoreLocation, $StoreName, $cert.Subject, $cert.Thumbprint)
            return
        }

        $store.Add($cert)
        Write-Detail "已将证书导入到 $StoreLocation\\${StoreName}：$($cert.Subject)（$($cert.Thumbprint)）"
        Write-Log ("Imported certificate into {0}\\{1}: {2} ({3})" -f $StoreLocation, $StoreName, $cert.Subject, $cert.Thumbprint)
    } finally {
        $store.Close()
    }
}

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [bool]$DefaultYes = $false
    )

    $suffix = if ($DefaultYes) { ' [Y/n]' } else { ' [y/N]' }
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $raw = Read-Host ($Prompt + $suffix)
        } catch {
            return $false
        }

        if ($null -eq $raw) { $raw = '' }
        $raw = $raw.Trim()

        if ($raw.Length -eq 0) {
            return $DefaultYes
        }

        if ($raw -match '^(?i:y|yes)$') { return $true }
        if ($raw -match '^(?i:n|no)$') { return $false }

        Write-Info '请输入 Y 或 N。'
    }
    return $DefaultYes
}

function Resolve-SingleFileInScriptDir {
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$What
    )

    $dir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    # 强制转数组，确保在 Windows PowerShell 5.1 + StrictMode 下访问 .Count 始终安全。
    $matches = @(Get-ChildItem -LiteralPath $dir -Filter $Pattern -File -ErrorAction SilentlyContinue)
    if ($matches.Count -eq 0) {
        return $null
    }
    if ($matches.Count -gt 1) {
        $names = ($matches | Select-Object -ExpandProperty Name) -join ', '
        throw "在目录 ${dir} 找到多个 ${What} 文件：$names。请确保该目录下只有一个 ${What} 文件。"
    }
    return $matches[0].FullName
}

function Get-MsixIdentityName {
    param([Parameter(Mandatory = $true)][string]$MsixPath)

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null
        $zip = [System.IO.Compression.ZipFile]::OpenRead($MsixPath)
        try {
            $entry = $zip.Entries | Where-Object { $_.FullName -ieq 'AppxManifest.xml' } | Select-Object -First 1
            if (-not $entry) { return $null }

            $sr = New-Object System.IO.StreamReader($entry.Open())
            try {
                [xml]$xml = $sr.ReadToEnd()
            } finally {
                $sr.Dispose()
            }

            return $xml.Package.Identity.Name
        } finally {
            $zip.Dispose()
        }
    } catch {
        return $null
    }
}

$MsixPath = Resolve-SingleFileInScriptDir -Pattern '*.msix' -What 'MSIX'
if (-not $MsixPath) {
    throw '脚本同目录下未找到 *.msix。请将 Install.ps1 与 MSIX 放在同一目录。'
}
$MsixPath = (Resolve-Path -LiteralPath $MsixPath).Path

$CerPath = Resolve-SingleFileInScriptDir -Pattern '*.cer' -What 'CER'
if (-not $CerPath) {
    throw '脚本同目录下未找到 *.cer。该项目仅支持使用构建时证书并导入到 LocalMachine 后安装。'
}
$CerPath = (Resolve-Path -LiteralPath $CerPath).Path

$identityName = Get-MsixIdentityName -MsixPath $MsixPath
if (-not $identityName) {
    throw '无法从 MSIX 中读取 AppxManifest.xml 的 Identity.Name。'
}
if ($identityName -ne $script:ExpectedIdentityName) {
    throw "MSIX 包名不符合项目规定。期望：$($script:ExpectedIdentityName)，实际：$identityName"
}

Import-CertificateLocalMachineTrusted -CerPath $CerPath

Write-Info "正在安装：$MsixPath"
try {
    Add-AppxPackage -Path $MsixPath -ForceApplicationShutdown -ErrorAction Stop
} catch {
    $hresult = $null
    try { $hresult = $_.Exception.HResult } catch { }

    # 0x80073D02：包资源正在被占用（常见原因：explorer.exe 加载了右键菜单扩展 DLL）。
    # 处理方式：关闭资源管理器并重试一次。
    if ($hresult -eq ([int]0x80073D02) -or ($_.Exception.Message -match '0x80073D02')) {
        Write-Info '安装被阻止（0x80073D02）：资源正在被占用，正在自动处理...'

        # 关闭 Explorer，并结束所有加载了扩展 DLL 的进程（常见是 dllhost.exe）。
        # 在 Add-AppxPackage 成功前不要启动 Explorer，否则可能立刻再次锁住 DLL。
        Stop-WindowsExplorer
        Stop-ProcessesUsingModule -ModuleName 'Code Modern Explorer Menu.dll'
        Stop-ProcessesUsingModule -ModuleName 'Code Insiders Modern Explorer Menu.dll'

        # 在 Explorer 未运行的情况下重试安装。
        # （如果是 Explorer 持有 DLL，ForceApplicationShutdown 并不能解决占用。）

        try {
            Add-AppxPackage -Path $MsixPath -ForceApplicationShutdown -ErrorAction Stop
            Write-Info '重试安装成功。'
            $hresult = $null
            Start-WindowsExplorer
        } catch {
            # 若仍被占用，则进入最后手段：移除旧版本后再安装。
            $hresult = $null
            try { $hresult = $_.Exception.HResult } catch { }
            if (-not ($hresult -eq ([int]0x80073D02) -or ($_.Exception.Message -match '0x80073D02'))) {
                Start-WindowsExplorer
                throw
            }

            $identityName = Get-MsixIdentityName -MsixPath $MsixPath
            if ($identityName) {
                Write-Info "仍被占用。正在移除旧版本并重试安装：$identityName"
                $existing = Get-AppxPackage -Name $identityName -ErrorAction SilentlyContinue
                foreach ($pkg in $existing) {
                    try {
                        Write-Detail "正在移除：$($pkg.PackageFullName)"
                        Remove-AppxPackageWithTimeout -PackageFullName $pkg.PackageFullName -TimeoutSeconds 45
                    } catch {
                        Write-Info "移除失败：$($_.Exception.Message)"
                    }
                }

                # 重新安装前再确保没有残留占用。
                Stop-ProcessesUsingModule -ModuleName 'Code Modern Explorer Menu.dll'
                Stop-ProcessesUsingModule -ModuleName 'Code Insiders Modern Explorer Menu.dll'
                Add-AppxPackage -Path $MsixPath -ForceApplicationShutdown -ErrorAction Stop
                Write-Info '重新安装成功。'
                $hresult = $null
                Start-WindowsExplorer
            } else {
                Start-WindowsExplorer
                throw
            }
        }
    }

    # 0x800B0109：证书链终止于不受信任的根证书。
    # 在一些系统上，即使是按用户安装，AppX 验证也可能要求机器级信任（LocalMachine 存储）。
    if (($hresult -eq ([int]0x800B0109) -or ($_.Exception.Message -match '0x800B0109')) -and $CerPath) {
        Write-Info 'MSIX 签名链仍不受信任。正在重新导入 LocalMachine 信任后重试安装...'
        Import-CertificateLocalMachineTrusted -CerPath $CerPath
        Add-AppxPackage -Path $MsixPath -ForceApplicationShutdown -ErrorAction Stop
    }
    throw
}
Write-Info '完成。'

$installed = Get-AppxPackage -Name $script:ExpectedIdentityName -ErrorAction SilentlyContinue
if ($installed) {
    Write-Info "已验证当前用户已安装：$($script:ExpectedIdentityName)"
} else {
    Write-Info "安装已结束，但当前用户看不到该包：$($script:ExpectedIdentityName)"
    Write-Info '如果过程中弹出了 UAC，请确认安装步骤没有只在提升权限的管理员会话中执行。'
}

if (Read-YesNo -Prompt '是否现在重启 Windows 资源管理器以应用上下文菜单更改？（将关闭已打开的资源管理器窗口）' -DefaultYes $false) {
    Restart-WindowsExplorer
    Write-Info '已重启资源管理器。'
} else {
    Write-Info '已跳过重启资源管理器。若右键菜单未更新，可稍后手动重启资源管理器或注销/重新登录。'
}
