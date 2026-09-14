<#
    Update-DSH.ps1
    ==============
    In-place updater for the portable DeepSeekHarness runtime
    ( <InstallRoot>\runtime\node_modules\@deepseek-ai\dsh ).

    Design goals
    ------------
    1. Survive the current DSH session ending. Launch it by double-clicking
       Update-DSH.bat, i.e. from Explorer: it is NOT a child of the DSH process
       tree, so stopping or restarting DSH cannot interrupt the update.
    2. Keep downtime tiny. All slow work (resolve / npm install / assembly /
       pre-flight execution of the new build) happens BEFORE DSH is stopped.
       Only the directory swap needs DSH down, and that is a same-volume rename.
    3. Reproduce the existing layout. The portable runtime keeps its dependency
       tree EMBEDDED inside the package ( dsh\node_modules\* ), and
       %USERPROFILE%\.dsh\profiles\node_modules holds ~241 junctions pointing
       into that embedded tree. A modern flat npm layout would leave every one
       of them dangling, so the embedded layout is rebuilt explicitly.
    4. Never leave a half-installed runtime. The old package is renamed (not
       deleted) before the swap; any failure rolls it back.
    5. Verify before touching anything. The assembled build is executed
       ( node lib/bin.js --version ) while DSH is still running, and a verified
       assembled build is reused on the next run instead of being rebuilt.

    Usage
    -----
        Update-DSH.bat                        -> update to dist-tag "latest"
        Update-DSH.bat -Version 0.1.5-rc.1    -> pin an exact version
        Update-DSH.bat -DryRun                -> stage + assemble + verify only
        Update-DSH.bat -NoRestart             -> do not restart DSH afterwards
        Update-DSH.bat -RemoveBackup          -> delete the backup after success

    Logs: <InstallRoot>\_update\logs\update-<timestamp>.log
#>
[CmdletBinding()]
param(
    [string]$Version = 'latest',
    [int]$Port = 3080,
    [switch]$DryRun,
    [switch]$NoRestart,
    [switch]$RemoveBackup
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- paths
$UpdateDir  = $PSScriptRoot                                   # <InstallRoot>\_update
$InstallDir = Split-Path -Parent $UpdateDir                   # <InstallRoot>
$RuntimeDir = Join-Path $InstallDir 'runtime'
$NodeExe    = Join-Path $RuntimeDir 'node.exe'
$DshParent  = Join-Path (Join-Path $RuntimeDir 'node_modules') '@deepseek-ai'
$DshDir     = Join-Path $DshParent 'dsh'
$StartBat   = Join-Path $InstallDir 'start.bat'
$ProfileMod = Join-Path (Join-Path $env:USERPROFILE '.dsh') 'profiles\node_modules'

$LogDir   = Join-Path $UpdateDir 'logs'
$StageDir = Join-Path $UpdateDir 'stage'
$AsmDir   = Join-Path $UpdateDir 'assembled'
$Stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile  = Join-Path $LogDir ("update-{0}.log" -f $Stamp)

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# ---------------------------------------------------------------- helpers
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0}  [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
}

function Fail {
    param([string]$Message)
    Write-Log $Message 'ERROR'
    Write-Log 'ABORTED.' 'ERROR'
    throw $Message
}

function Get-PackageVersion {
    param([string]$PackageDir)
    $pkgJson = Join-Path $PackageDir 'package.json'
    if (-not (Test-Path -LiteralPath $pkgJson)) { return $null }
    try { return (Get-Content -LiteralPath $pkgJson -Raw | ConvertFrom-Json).version } catch { return $null }
}

function Get-PortOwnerPids {
    param([int]$TargetPort)
    $pids = @()
    try {
        $pids = @(Get-NetTCPConnection -LocalPort $TargetPort -State Listen -ErrorAction Stop |
                  Select-Object -ExpandProperty OwningProcess -Unique)
    } catch {
        $pattern = ':{0}\s' -f $TargetPort
        $pids = @(netstat -ano | Select-String $pattern | Select-String 'LISTENING' |
                  ForEach-Object { ($_.Line -split '\s+')[-1] } | Select-Object -Unique)
    }
    $clean = @()
    foreach ($p in $pids) {
        $n = 0
        if ([int]::TryParse([string]$p, [ref]$n) -and $n -gt 0) { $clean += $n }
    }
    return $clean
}

function Test-Build {
    param([string]$PackageDir)
    Push-Location $PackageDir
    try {
        $out  = (& $NodeExe 'lib/bin.js' --version 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    return [pscustomobject]@{ Output = $out; Code = $code }
}

function Test-AssembledReusable {
    param([string]$TargetVersion)
    if (-not $TargetVersion) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $AsmDir 'lib\bin.js'))) { return $false }
    $v = Get-PackageVersion -PackageDir $AsmDir
    if ($v -ne $TargetVersion) { return $false }
    $chk = Test-Build -PackageDir $AsmDir
    if ($chk.Code -ne 0 -or -not $chk.Output) { return $false }
    return $true
}

function Report-ProfileJunctions {
    if (-not (Test-Path -LiteralPath $ProfileMod)) {
        Write-Log ' no ~/.dsh/profiles/node_modules to inspect'
        return
    }
    $rp = [System.IO.FileAttributes]::ReparsePoint
    $links = @(Get-ChildItem -LiteralPath $ProfileMod -Force -ErrorAction SilentlyContinue |
               Where-Object { ($_.Attributes -band $rp) -ne 0 })
    if ($links.Count -eq 0) {
        Write-Log ' profile resolution chain: no links found'
        return
    }
    $dangling = @()
    foreach ($l in $links) {
        $t = [string]$l.Target
        if (-not $t) { continue }
        if (-not (Test-Path -LiteralPath $t)) { $dangling += $l }
    }
    Write-Log (" profile resolution chain: {0} links, {1} dangling" -f $links.Count, $dangling.Count)
    if ($dangling.Count -gt 0) {
        Write-Log ' dangling links (harmless unless a plugin actually requires them):' 'WARN'
        foreach ($d in ($dangling | Select-Object -First 15)) {
            Write-Log ("   {0}  ->  {1}" -f $d.Name, [string]$d.Target) 'WARN'
        }
        if ($dangling.Count -gt 15) { Write-Log ("   ... and {0} more" -f ($dangling.Count - 15)) 'WARN' }
        Write-Log ' If a plugin fails to load after the update, delete the folder' 'WARN'
        Write-Log '   %USERPROFILE%\.dsh\profiles\node_modules' 'WARN'
        Write-Log ' and restart DSH so the chain is rebuilt.' 'WARN'
    }
}

# ---------------------------------------------------------------- banner
Write-Log '=========================================================='
Write-Log ' DeepSeekHarness runtime updater'
Write-Log (" install root : {0}" -f $InstallDir)
Write-Log (" target       : @deepseek-ai/dsh@{0}" -f $Version)
Write-Log (" log          : {0}" -f $LogFile)
if ($DryRun) { Write-Log ' mode         : DRY RUN (no swap, no restart)' }
Write-Log '=========================================================='

# ================================================================ 1. pre-flight
Write-Log '--- step 1/7  pre-flight checks'

if (-not (Test-Path -LiteralPath $NodeExe)) { Fail "runtime\node.exe not found: $NodeExe" }
if (-not (Test-Path -LiteralPath (Join-Path $DshDir 'lib\bin.js'))) { Fail "dsh package not found: $DshDir" }

$oldVer = Get-PackageVersion -PackageDir $DshDir
Write-Log (" current dsh version : {0}" -f $oldVer)

$npmCmd = (Get-Command npm.cmd -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $npmCmd) {
    $fallback = Join-Path $env:ProgramFiles 'nodejs\npm.cmd'
    if (Test-Path -LiteralPath $fallback) { $npmCmd = $fallback }
}
if (-not $npmCmd) { Fail 'npm.cmd not found. Install Node.js or make sure npm is on PATH.' }
Write-Log (" npm                 : {0}" -f $npmCmd)

$driveLetter = $InstallDir.Substring(0, 1)
$free = (Get-PSDrive -Name $driveLetter).Free
Write-Log (" free space on {0}: {1:N1} GB" -f $driveLetter, ($free / 1GB))
if ($free -lt 3GB) { Fail 'Less than 3 GB free. Staging plus the backup need about 1 GB.' }

# resolve the target version so an already-prepared build can be reused
$resolved = $null
try {
    $raw = (& $npmCmd view ("@deepseek-ai/dsh@{0}" -f $Version) version --json 2>&1 | Out-String).Trim()
    $raw = $raw.Trim('"')
    if ($raw -match '^\d+\.\d+\.\d+') { $resolved = $raw }
} catch { }
if ($resolved) { Write-Log (" resolved target     : {0}" -f $resolved) }
else { Write-Log ' could not resolve the target version from the registry; will install directly.' 'WARN' }

# ================================================================ 2-3. stage + assemble
if (Test-AssembledReusable -TargetVersion $resolved) {
    Write-Log '--- step 2-3/7  reusing the assembled build that already passed verification'
} else {
    Write-Log '--- step 2/7  npm install into the staging dir (DSH stays online)'
    if (Test-Path -LiteralPath $StageDir) {
        Write-Log ' removing the previous staging dir'
        Remove-Item -LiteralPath $StageDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $StageDir | Out-Null
    @'
{
  "name": "dsh-update-stage",
  "private": true,
  "version": "0.0.0"
}
'@ | Set-Content -LiteralPath (Join-Path $StageDir 'package.json') -Encoding UTF8

    Write-Log (" running: npm install @deepseek-ai/dsh@{0}" -f $Version)
    Push-Location $StageDir
    try {
        & $npmCmd install ("@deepseek-ai/dsh@{0}" -f $Version) --no-audit --no-fund --no-package-lock --loglevel=error
        $npmCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($npmCode -ne 0) { Fail ("npm install failed with exit code {0}; see the output above." -f $npmCode) }

    $stageModules = Join-Path $StageDir 'node_modules'
    $stagedPkg    = Join-Path (Join-Path $stageModules '@deepseek-ai') 'dsh'
    if (-not (Test-Path -LiteralPath (Join-Path $stagedPkg 'lib\bin.js'))) {
        Fail "the staged package is incomplete (lib\bin.js missing): $stagedPkg"
    }
    $newVer = Get-PackageVersion -PackageDir $stagedPkg
    Write-Log (" staged dsh version  : {0}" -f $newVer)

    Write-Log '--- step 3/7  rebuilding the embedded dependency layout (DSH stays online)'
    if (Test-Path -LiteralPath $AsmDir) { Remove-Item -LiteralPath $AsmDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $AsmDir | Out-Null

    # 3a. package body, hidden entries included
    Get-ChildItem -LiteralPath $stagedPkg -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $AsmDir -Recurse -Force
    }
    Write-Log ' copied the package body'

    # 3b. flat dependencies -> assembled\node_modules
    $embedded = Join-Path $AsmDir 'node_modules'
    New-Item -ItemType Directory -Force -Path $embedded | Out-Null

    $moved = 0
    Get-ChildItem -LiteralPath $stageModules -Force | Where-Object { $_.Name -ne '@deepseek-ai' } | ForEach-Object {
        Move-Item -LiteralPath $_.FullName -Destination $embedded -Force
        $moved++
    }

    # 3c. other @deepseek-ai scope packages (everything except dsh itself)
    $scopeDir = Join-Path $stageModules '@deepseek-ai'
    if (Test-Path -LiteralPath $scopeDir) {
        $others = @(Get-ChildItem -LiteralPath $scopeDir -Force | Where-Object { $_.Name -ne 'dsh' })
        if ($others.Count -gt 0) {
            $destScope = Join-Path $embedded '@deepseek-ai'
            New-Item -ItemType Directory -Force -Path $destScope | Out-Null
            foreach ($o in $others) {
                Move-Item -LiteralPath $o.FullName -Destination $destScope -Force
                $moved++
            }
        }
    }

    $embeddedCount = @(Get-ChildItem -LiteralPath $embedded -Force -ErrorAction SilentlyContinue).Count
    Write-Log (" embedded dependency entries: {0}  (moved out of the flat tree: {1})" -f $embeddedCount, $moved)
    if ($embeddedCount -lt 100) {
        Fail ("the assembled dependency tree looks too small ({0} entries); refusing to swap." -f $embeddedCount)
    }
}

# ================================================================ 4. run the new build
Write-Log '--- step 4/7  executing the assembled build (DSH stays online)'
$probe = Test-Build -PackageDir $AsmDir
Write-Log (" probe output: '{0}'  (exit {1})" -f $probe.Output, $probe.Code)
if ($probe.Code -ne 0 -or -not $probe.Output) { Fail 'the assembled build does not run; nothing was swapped.' }
Write-Log ' the assembled build runs OK'

if ($DryRun) {
    Write-Log '--- DRY RUN: stopping here, nothing was swapped.'
    Write-Log (" assembled tree kept at: {0}" -f $AsmDir)
    Write-Log ' rerun without -DryRun to perform the swap (it will reuse this build).'
    exit 0
}

# ================================================================ 5. stop DSH
Write-Log '--- step 5/7  stopping DSH'
$pids = Get-PortOwnerPids -TargetPort $Port
if ($pids.Count -eq 0) {
    Write-Log (" nothing is listening on port {0}; DSH does not look like it is running." -f $Port)
} else {
    Write-Log (" listener PIDs on port {0}: {1}" -f $Port, ($pids -join ', '))
    Write-Log ' stopping DSH in 10 seconds - press Ctrl+C now to cancel.'
    for ($i = 10; $i -ge 1; $i--) {
        Write-Host ("`r  ... {0,2} s " -f $i) -NoNewline
        Start-Sleep -Seconds 1
    }
    Write-Host ''
    foreach ($p in $pids) {
        Write-Log (" taskkill /PID {0} /T /F" -f $p)
        & taskkill.exe /PID $p /T /F 2>&1 | ForEach-Object { Write-Log ("   {0}" -f $_) }
    }
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline) {
        if ((Get-PortOwnerPids -TargetPort $Port).Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    }
    if ((Get-PortOwnerPids -TargetPort $Port).Count -ne 0) {
        Fail ("port {0} is still held. Close DeepSeekHarness by hand and run this script again." -f $Port)
    }
    Write-Log ' port released'
}

# ================================================================ 6. swap
Write-Log '--- step 6/7  swapping the package'
$backupDir = '{0}.bak-{1}-{2}' -f $DshDir, $oldVer, $Stamp
$swapped = $false

try {
    Move-Item -LiteralPath $DshDir -Destination $backupDir
    Write-Log (" old package renamed -> {0}" -f $backupDir)
    Move-Item -LiteralPath $AsmDir -Destination $DshDir
    Write-Log ' new package moved into place'
    $swapped = $true
} catch {
    Write-Log (" swap failed: {0}" -f $_.Exception.Message) 'ERROR'
}

if ($swapped) {
    Write-Log ' verifying the installed build'
    $final = Test-Build -PackageDir $DshDir
    if ($final.Code -ne 0 -or -not $final.Output) {
        Write-Log (" installed build does not run: '{0}' (exit {1})" -f $final.Output, $final.Code) 'ERROR'
        $swapped = $false
    } else {
        Write-Log (" installed version : {0}" -f $final.Output)
    }
}

if (-not $swapped) {
    Write-Log '--- rolling back' 'ERROR'
    if ((Test-Path -LiteralPath $DshDir) -and -not (Test-Path -LiteralPath (Join-Path $DshDir 'lib\bin.js'))) {
        $badDir = '{0}.failed-{1}' -f $DshDir, $Stamp
        Move-Item -LiteralPath $DshDir -Destination $badDir -ErrorAction SilentlyContinue
        Write-Log (" broken package parked at {0}" -f $badDir)
    }
    if (Test-Path -LiteralPath $backupDir) {
        if (Test-Path -LiteralPath $DshDir) { Remove-Item -LiteralPath $DshDir -Recurse -Force -ErrorAction SilentlyContinue }
        Move-Item -LiteralPath $backupDir -Destination $DshDir
        Write-Log ' the previous package is back in place'
    }
    Fail 'update failed; the previous version was restored.'
}

Write-Log ' checking the profile resolution chain'
Report-ProfileJunctions

# ================================================================ 6b. launcher adapter
# dsh 0.1.5+ prints a one-time token URL and answers the bare origin with 401.
# The shipped controller.ps1 opens the bare origin, so adapt the launcher here:
# right after the swap, before DSH is started again. The adapter is idempotent
# and refuses to touch an upstream layout it does not recognise.
$fixScript = Join-Path $UpdateDir 'Fix-Launcher.ps1'
if (Test-Path -LiteralPath $fixScript) {
    Write-Log '--- step 6b  adapting controller.ps1 for the dsh token auth'
    try {
        & $fixScript *>&1 | ForEach-Object { Write-Log ("   {0}" -f $_) }
        if ($LASTEXITCODE -ne 0) {
            Write-Log (" launcher adapter exited with code {0}" -f $LASTEXITCODE) 'WARN'
            Write-Log ' the WebUI may open a 401 page; run Fix-Launcher.bat by hand.' 'WARN'
        }
    } catch {
        Write-Log (" launcher adapter failed: {0}" -f $_.Exception.Message) 'WARN'
        Write-Log ' the WebUI may open a 401 page; run Fix-Launcher.bat by hand.' 'WARN'
    }
} else {
    Write-Log (" Fix-Launcher.ps1 not found at {0}; skipping launcher adaptation" -f $fixScript) 'WARN'
}

# ================================================================ 7. restart
Write-Log '--- step 7/7  restarting DSH'
if ($NoRestart) {
    Write-Log ' -NoRestart given; start DeepSeekHarness yourself.'
} elseif (Test-Path -LiteralPath $StartBat) {
    Start-Process -FilePath $StartBat -WorkingDirectory $InstallDir
    Write-Log ' start.bat launched (control window + WebUI + browser will come up)'
} else {
    Write-Log (" start.bat not found at {0}" -f $StartBat) 'WARN'
}

if ($RemoveBackup) {
    if (Test-Path -LiteralPath $backupDir) {
        Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log ' backup deleted (-RemoveBackup)'
    }
} else {
    Write-Log (" backup kept for rollback: {0}" -f $backupDir)
    Write-Log ' delete that folder once the new version looks fine (frees about 280 MB).'
}

Write-Log '=========================================================='
Write-Log (" DONE: {0} -> {1}" -f $oldVer, $newVer)
Write-Log ' To roll back by hand: stop DSH, delete the new "dsh" folder,'
Write-Log ' rename the .bak folder back to "dsh", start DSH again.'
Write-Log '=========================================================='
