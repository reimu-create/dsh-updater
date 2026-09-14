<#
    Fix-Launcher.ps1 —— 让便携版启动器适配新版 dsh 的 token 认证
    ============================================================

    背景
    ----
    dsh 0.1.5 起，`dsh web` 启动后会打印一个带一次性 token 的 URL：

        dsh web: http://127.0.0.1:3080/?token=xxxxx

    裸地址 http://127.0.0.1:3080/ 会返回 401 Unauthorized（实测 0.1.5-rc.1）。
    而上游 controller.ps1 固定用裸地址打开浏览器，于是页面打不开，只能手动去
    logs\dsh.out.log 里翻 token。旧版 dsh（如 0.1.1-rc.2）没有认证，裸地址可用。

    本脚本对 controller.ps1 做 5 处幂等注入，让它：
      · 启动后从 logs\dsh.out.log 解析出带 token 的 URL；
      · 用该 URL 打开浏览器（应用窗口 / 默认浏览器 / 预热 curl 三条路径都覆盖）；
      · 解析不到 token 时（旧版 dsh）自动回落到原来的裸地址。

    特性
    ----
    * 幂等：逐项检查，已应用的项跳过，可反复运行。
    * 保守：任一锚点找不到（上游结构变了）就整体放弃，绝不猜测、绝不部分写入。
    * 安全：写回前先备份，写回前做 PowerShell 语法校验，校验失败不落盘。
    * 保编码：原文件是 UTF-8 with BOM + LF，写回保持完全一致。

    用法
    ----
        Fix-Launcher.bat                    修复 <安装根>\controller.ps1
        Fix-Launcher.bat -DryRun            只报告会做什么，不写文件
        Fix-Launcher.bat -Path X.ps1        对指定文件操作（测试/其它安装）

    何时需要运行
    ------------
    1. 每次用官方 update.bat 更新启动器之后（它会把 controller.ps1 覆盖回原版）；
    2. 每次用本目录的 Update-DSH.bat 更新 dsh 本体之后（它会自动调用本脚本）；
    3. 任何时候怀疑启动器不会带 token 打开浏览器时。
#>
[CmdletBinding()]
param(
    [string]$Path,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$UpdateDir  = $PSScriptRoot
$InstallDir = Split-Path -Parent $UpdateDir
if (-not $Path) { $Path = Join-Path $InstallDir 'controller.ps1' }

$LogDir      = Join-Path $UpdateDir 'logs'
$BackupDir   = Join-Path $UpdateDir 'launcher-backup'
$Marker      = 'DSH-AUTH-ADAPTER'
$Stamp       = Get-Date -Format 'yyyyMMdd-HHmmss'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Say {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0}  [{1,-5}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host $line
    try { Add-Content -LiteralPath (Join-Path $LogDir 'launcher-fix.log') -Value $line -Encoding UTF8 } catch { }
}

Say '=========================================================='
Say ' controller.ps1 launcher adapter (dsh 0.1.5+ token auth)'
Say (" target : {0}" -f $Path)
if ($DryRun) { Say ' mode   : DRY RUN (nothing is written)' }
Say '=========================================================='

if (-not (Test-Path -LiteralPath $Path)) {
    Say ("controller.ps1 not found: {0}" -f $Path) 'ERROR'
    exit 1
}

# ---------------------------------------------------------------- read
$raw     = [System.IO.File]::ReadAllBytes($Path)
$hasBom  = ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)
$text    = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
$lf      = if ($text -match "`r`n") { "`r`n" } else { "`n" }
Say (" encoding: UTF-8 {0}, newline {1}" -f $(if ($hasBom) { 'with BOM' } else { 'no BOM' }), $(if ($lf -eq "`r`n") { 'CRLF' } else { 'LF' }))

# 只处理真正的 DeepSeekHarness 启动器，避免误伤
if ($text -notmatch 'DeepSeekHarness' -or $text -notmatch '\$Port') {
    Say ' this file does not look like the DeepSeekHarness controller; refusing to touch it.' 'ERROR'
    exit 1
}

$original = $text
$applied  = @()
$skipped  = @()

# ---------------------------------------------------------------- 1. WebUrl 变量
if ($text -match '\$script:WebUrl\s*=\s*\$Url') {
    $skipped += 'WebUrl 变量初始化'
} else {
    $m = [regex]::Match($text, '(?m)^\$Url[ \t]*=[ \t]*"http://127\.0\.0\.1:\$Port".*$')
    if (-not $m.Success) {
        Say ' anchor not found: $Url = "http://127.0.0.1:$Port"  (upstream layout changed)' 'ERROR'
        Say ' nothing was modified.' 'ERROR'
        exit 1
    }
    $ins = '$script:WebUrl = $Url   # ' + $Marker + ': 打开浏览器用的实际 URL（新版 dsh 带 ?token= 认证，启动后从日志解析）'
    $text = $text.Insert($m.Index + $m.Length, $lf + $ins)
    $applied += 'WebUrl 变量初始化'
}

# ---------------------------------------------------------------- 2. 应用窗口 --app=
if ($text.Contains('--app=$script:WebUrl')) {
    $skipped += '应用窗口 --app= 参数'
} elseif ($text.Contains('--app=$Url')) {
    $text = $text.Replace('--app=$Url', '--app=$script:WebUrl')
    $applied += '应用窗口 --app= 参数'
} else {
    Say ' anchor not found: --app=$Url  (upstream layout changed)' 'ERROR'
    Say ' nothing was modified.' 'ERROR'
    exit 1
}

# ---------------------------------------------------------------- 3. 默认浏览器回落
if ($text.Contains('Start-Process $script:WebUrl -ErrorAction')) {
    $skipped += '默认浏览器回落'
} elseif ($text.Contains('Start-Process $Url -ErrorAction')) {
    $text = $text.Replace('Start-Process $Url -ErrorAction', 'Start-Process $script:WebUrl -ErrorAction')
    $applied += '默认浏览器回落'
} else {
    Say ' anchor not found: Start-Process $Url -ErrorAction  (upstream layout changed)' 'ERROR'
    Say ' nothing was modified.' 'ERROR'
    exit 1
}

# ---------------------------------------------------------------- 4. 预热 curl
if ($text.Contains("-ArgumentList @('-s', '-o', 'NUL', `$script:WebUrl)")) {
    $skipped += '预热 curl'
} elseif ($text.Contains("-ArgumentList @('-s', '-o', 'NUL', `$Url)")) {
    $text = $text.Replace("-ArgumentList @('-s', '-o', 'NUL', `$Url)", "-ArgumentList @('-s', '-o', 'NUL', `$script:WebUrl)")
    $applied += '预热 curl'
} else {
    Say ' anchor not found: curl -ArgumentList ... $Url  (upstream layout changed)' 'ERROR'
    Say ' nothing was modified.' 'ERROR'
    exit 1
}

# ---------------------------------------------------------------- 5. token 解析块
if ($text.Contains('/\?token=')) {
    $skipped += 'token 解析块'
} else {
    $m = [regex]::Match($text, '(?m)^([ \t]*)Write-CtrlLog "WebUI listening at \$Url; opening browser\."')
    if (-not $m.Success) {
        Say ' anchor not found: Write-CtrlLog "WebUI listening at $Url; ..."  (upstream layout changed)' 'ERROR'
        Say ' nothing was modified.' 'ERROR'
        exit 1
    }
    $ind = $m.Groups[1].Value
    $block = @(
        ($ind + '# ' + $Marker + ': 解析 dsh 输出的认证 URL（新版 dsh 为 http://127.0.0.1:port/?token=xxx；无认证的旧版回落裸地址）'),
        ($ind + 'try {'),
        ($ind + '    for ($i = 0; $i -lt 20; $i++) {'),
        ($ind + '        $authLine = @(Get-Content -LiteralPath $DshOutLog -Tail 8 -ErrorAction SilentlyContinue) |'),
        ($ind + '            Where-Object { $_ -match ''/\?token='' } | Select-Object -Last 1'),
        ($ind + '        if ($authLine) {'),
        ($ind + '            $m = [regex]::Match($authLine, ''http://[^\s]+'')'),
        ($ind + '            if ($m.Success) { $script:WebUrl = $m.Value; break }'),
        ($ind + '        }'),
        ($ind + '        Start-Sleep -Milliseconds 500'),
        ($ind + '    }'),
        ($ind + '} catch { }')
    ) -join $lf
    $text = $text.Insert($m.Index, $block + $lf)
    $applied += 'token 解析块'
}

# ---------------------------------------------------------------- report
if ($skipped.Count -gt 0) { Say (" already in place: {0}" -f ($skipped -join ', ')) }
if ($applied.Count -eq 0) {
    Say ' RESULT: controller.ps1 is already adapted; no change needed.'
    exit 0
}
Say (" to apply: {0}" -f ($applied -join ', '))

if ($DryRun) {
    Say ' DRY RUN: stopping here, nothing was written.'
    exit 0
}

# ---------------------------------------------------------------- syntax check
$tokens = $null; $errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count -gt 0) {
    Say (" patched file has {0} syntax error(s); NOT writing it out:" -f $errors.Count) 'ERROR'
    foreach ($e in $errors) { Say ("   line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) 'ERROR' }
    Say ' controller.ps1 left untouched.' 'ERROR'
    exit 1
}
Say ' syntax check passed'

# ---------------------------------------------------------------- backup + write
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
$backup = Join-Path $BackupDir ("controller-{0}.ps1" -f $Stamp)
Copy-Item -LiteralPath $Path -Destination $backup -Force
Say (" backup: {0}" -f $backup)

try {
    $enc = New-Object System.Text.UTF8Encoding($hasBom)
    [System.IO.File]::WriteAllText($Path, $text, $enc)
    Say (" written: {0}  ({1} -> {2} bytes)" -f $Path, $raw.Length, ([System.IO.File]::ReadAllBytes($Path)).Length)
} catch {
    Say (" write failed: {0}" -f $_.Exception.Message) 'ERROR'
    Say (" restoring from backup ..." ) 'WARN'
    Copy-Item -LiteralPath $backup -Destination $Path -Force
    exit 1
}

Say ' RESULT: controller.ps1 adapted. WebUI will now open with its token URL.'
Say '=========================================================='
exit 0
