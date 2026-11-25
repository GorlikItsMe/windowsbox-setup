#Requires -Version 5.1
<#
.SYNOPSIS
    Fresh Windows 11 in one command: debloat + developer toolchain.

.DESCRIPTION
    Single self-contained file. No config files, no modules, no repo checkout.
    The package list and the settings live in the $CONFIG block below - edit it
    or leave the defaults.

    Run it with one line on a clean Windows 11 box:

        powershell -c "irm <raw-url>/win-setup.ps1 | iex"

    The script asks a few questions (ENTER accepts the default), elevates
    itself through UAC, then runs four phases:

      1. debloat   - runs Win11Debloat (github.com/Raphire/Win11Debloat) for us
      2. settings  - long paths, Developer Mode, execution policy, features
      3. packages  - winget installs (git, Node LTS, Python, Cursor, ...)
      4. postconf  - git config, PowerShell modules, global packages

    The debloat phase is delegated on purpose: it downloads the latest
    Win11Debloat release, verifies its SHA-256 when the release publishes one,
    and runs it with -RunDefaults -Silent. Win11Debloat keeps its own registry
    backup in %LOCALAPPDATA%\Win11Debloat\Backups.

    Everything this script does is logged to %LOCALAPPDATA%\win-setup\log-*.log.

.PARAMETER Yes
    Skip the questions and use the defaults (debloat on, optional group on).

.PARAMETER WhatIfOnly
    Print the whole plan. Changes nothing, needs no admin.

.PARAMETER Revert
    Opens Win11Debloat's restore window (it restores its own registry backups).

.PARAMETER Aggressive
    Extra debloat flags on top of Win11Debloat defaults: Copilot, Recall,
    Click to Do, widgets, chat, Xbox game bar/DVR, location, Bing, fast startup,
    delivery optimization.

.PARAMETER NoDebloat
    Leave Windows alone, only install software.

.PARAMETER NoOptional
    Install the Core group only (no Chrome, VS Code Insiders, Claude Desktop...).

.PARAMETER NoRestorePoint
    Do not create a System Restore point before debloating.

.PARAMETER RemoveOneDrive
    Uninstall OneDrive instead of just leaving it alone.

.PARAMETER Reboot
    Restart the machine when the script is done.

.PARAMETER Force
    Reinstall packages that are already present.

.PARAMETER Pause
    Wait for ENTER before closing (used when the script relaunches itself).

.EXAMPLE
    powershell -c "irm https://raw.githubusercontent.com/USER/REPO/main/win-setup.ps1 | iex"

.EXAMPLE
    .\win-setup.ps1 -WhatIfOnly
    .\win-setup.ps1 -Yes
    .\win-setup.ps1 -Yes -Aggressive -RemoveOneDrive -Reboot
    .\win-setup.ps1 -Yes -NoOptional
    .\win-setup.ps1 -Revert
#>
# NOTE: deliberately no [CmdletBinding()] and no BOM. A UTF-8 BOM at the start
# of the file breaks `irm <url> | iex` in PowerShell 5.1 (it stops recognising
# even #Requires and reports "Unexpected attribute 'CmdletBinding'"). Keep this
# file saved as UTF-8 *without* BOM.
param(
    [switch] $Yes,
    [switch] $WhatIfOnly,
    [switch] $Revert,
    [switch] $Pause,
    [switch] $Force,
    [switch] $NoDebloat,
    [switch] $Aggressive,
    [switch] $NoOptional,
    [switch] $NoRestorePoint,
    [switch] $RemoveOneDrive,
    [switch] $NoRemote,
    [switch] $NoT3Autostart,
    [switch] $OnlyRemote,
    [switch] $Reboot,
    [string] $GitUserName = '',
    [string] $GitUserEmail = '',
    [string] $Answers = ''
)

# ==========================================================================
#  CONFIG - the only part you normally edit
# ==========================================================================

# Raw URL of this file, used only when the script runs through `irm | iex`
# (there is no local file to relaunch elevated). Fill it in after you publish
# the repo, e.g. 'https://raw.githubusercontent.com/jan/win-setup/main/win-setup.ps1'.
$SourceUrl = 'https://raw.githubusercontent.com/GorlikItsMe/windowsbox-setup/main/win-setup.ps1'

$CONFIG = @{
    # Debloat is delegated to Win11Debloat (MIT, github.com/Raphire/Win11Debloat).
    # The latest release is downloaded, its SHA-256 is checked when published,
    # and it is run with BaseArgs (+ AggressiveArgs when -Aggressive).
    Debloat = @{
        Repo = 'Raphire/Win11Debloat'
        BaseArgs = @('-RunDefaults', '-Silent')
        AggressiveArgs = @(
            '-DisableCopilot'
            '-DisableRecall'
            '-DisableClickToDo'
            '-DisableAISvcAutoStart'
            '-DisableWidgets'
            '-HideChat'
            '-DisableBing'
            '-DisableSuggestions'
            '-RemoveGamingApps'
            '-DisableDVR'
            '-DisableGameBarIntegration'
            '-DisableLocationServices'
            '-DisableFindMyDevice'
            '-DisableFastStartup'
            '-DisableDeliveryOptimization'
        )
        # Always applied, regardless of -Aggressive. Your personal taste.
        PersonalArgs = @(
            '-EnableEndTask'          # "End task" in the taskbar context menu
            '-ShowKnownFileExt'       # show extensions for known file types
            '-RevertContextMenu'      # classic Windows 10 right-click menu
            '-ExplorerToThisPC'       # Explorer opens at This PC
            '-ClearStart'             # drop the pinned Store junk from Start
        )
    }

    Git = @{
        UserName      = ''            # empty = ask (or skip)
        UserEmail     = ''
        DefaultBranch = 'main'
        AutoCrlf      = 'true'        # 'input' if you share repos with Linux/macOS
        Editor        = 'code --wait' # used by git commit / rebase
        CredentialHelper = 'manager'  # Git Credential Manager, ships with Git for Windows
        GenerateSshKey   = $true      # create ~/.ssh/id_ed25519 when missing
        SshKeyComment    = ''         # defaults to UserEmail
        Aliases = [ordered]@{
            st   = 'status -sb'
            co   = 'checkout'
            br   = 'branch -vv'
            lg   = 'log --oneline --graph --decorate -20'
            last = 'log -1 HEAD --stat'
            undo = 'reset --soft HEAD~1'
        }
    }

    Settings = @{
        EnableLongPaths     = $true
        EnableDeveloperMode = $true
        ExecutionPolicy     = 'RemoteSigned'
        SetTimezone         = ''      # e.g. 'Central European Standard Time'
    }

    # Browser-based remote access. TightVNC listens on loopback only, with VNC
    # authentication disabled; websockify binds to the Tailscale address, so the
    # only way in is your tailnet. Need a password? Enable it in TightVNC Server
    # and append &password=... to the URL.
    Remote = @{
        EnableNoVNC  = $true
        NoVncVersion = '1.7.0'
        WebPort      = 6080
        VncPort      = 5900
    }

    Autostart = @{
        T3Code = $true                # start T3 Code minimized at login
    }

    Packages = @{
        Core = @(
            'Git.Git'
            'GitHub.cli'
            'Microsoft.PowerShell'            # pwsh 7
            'Microsoft.WindowsTerminal'
            '7zip.7zip'
            'WinDirStat.WinDirStat'
            'Microsoft.VisualStudioCode'
            'Anysphere.Cursor'
            'Anthropic.ClaudeCode'            # `claude` CLI
            'Anomaly.OpenCode'                # `opencode` CLI
            'BurntSushi.ripgrep.MSVC'
            'sharkdp.fd'
            'junegunn.fzf'
            'jqlang.jq'
            'cURL.cURL'
            'Gyan.FFmpeg'
            'Fastfetch-cli.Fastfetch'
            'OpenJS.NodeJS.LTS'               # newest Node LTS
            'Oven-sh.Bun'
            'pnpm.pnpm'
            'Python.Python.3.15'              # newest Python in winget; bump when 3.16 ships
            'astral-sh.uv'
            'Microsoft.DotNet.SDK.8'
            'Tailscale.Tailscale'
            'T3Tools.T3Code'
            'Google.Antigravity'
        )
        Optional = @(
            'Google.Chrome'
            'Microsoft.VisualStudioCode.Insiders'
            'Anthropic.Claude'                # Claude desktop app
        )
        # Ids that must never be installed, even if they appear in some list.
        Excluded = @(
            # 'Microsoft.XboxGamingOverlay'
        )
    }

    VisualStudio = @{
        ProductId          = 'Microsoft.VisualStudio.2022.Community'
        Workloads          = @(
            'Microsoft.VisualStudio.Workload.ManagedDesktop'
            'Microsoft.VisualStudio.Workload.NetWeb'
        )
        IncludeRecommended = $true
    }

    PostConfig = @{
        InstallPSModules = @('Terminal-Icons', 'posh-git')   # needs pwsh 7
        NpmGlobals       = @()                               # e.g. @('typescript')
        BunGlobals       = @()                               # e.g. @('@opencode/cli')
    }
}

# ==========================================================================
#  end of config
# ==========================================================================

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --------------------------------------------------------------- plumbing --
$script:SelfPath = $null
if ($PSCommandPath) { $script:SelfPath = $PSCommandPath }
elseif ($MyInvocation.MyCommand.Path) { $script:SelfPath = $MyInvocation.MyCommand.Path }

$script:StateDir = Join-Path $env:LOCALAPPDATA 'win-setup'
if (-not (Test-Path -LiteralPath $script:StateDir)) {
    New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
}
$script:LogFile    = Join-Path $script:StateDir ("log-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:AnswersFile = Join-Path $script:StateDir 'answers.json'
$script:Results    = New-Object System.Collections.ArrayList
$script:Failed     = New-Object System.Collections.ArrayList
$script:NoVncUrl   = $null

function Write-Log {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('INFO', 'OK', 'SKIP', 'WARN', 'FAIL', 'STEP')][string] $Level = 'INFO'
    )
    $color = switch ($Level) {
        'OK' { 'Green' } 'SKIP' { 'DarkGray' } 'WARN' { 'Yellow' }
        'FAIL' { 'Red' } 'STEP' { 'Cyan' } default { 'Gray' }
    }
    $line = "{0} [{1,-4}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host $line -ForegroundColor $color
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
}

function Test-IsAdmin {
    (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-CanPrompt {
    if (-not [Environment]::UserInteractive) { return $false }
    try { if ([Console]::IsInputRedirected) { return $false } } catch { }
    return $true
}

function Read-YesNo {
    param([string] $Prompt, [bool] $Default = $true)
    $suffix = '[y/N]'
    if ($Default) { $suffix = '[Y/n]' }
    for ($i = 0; $i -lt 5; $i++) {
        try { $answer = Read-Host ("{0} {1}" -f $Prompt, $suffix) } catch { return $Default }
        if ($null -eq $answer) { return $Default }
        $answer = $answer.Trim().ToLowerInvariant()
        if ($answer -eq '') { return $Default }
        if ($answer -eq 'y' -or $answer -eq 'yes' -or $answer -eq 'tak' -or $answer -eq 't') { return $true }
        if ($answer -eq 'n' -or $answer -eq 'no' -or $answer -eq 'nie') { return $false }
        Write-Host '  answer y or n (ENTER = default)' -ForegroundColor DarkGray
    }
    return $Default
}

function Read-Text {
    param([string] $Prompt, [string] $Default = '')
    $shown = $Prompt
    if ($Default) { $shown = "{0} [{1}]" -f $Prompt, $Default }
    try { $value = Read-Host $shown } catch { return $Default }
    if ($null -eq $value) { return $Default }
    $value = $value.Trim()
    if ($value -eq '') { return $Default }
    return $value
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $seen    = @{}
    $parts   = @()
    foreach ($p in @((("$machine;$user") -split ';'))) {
        $p = $p.Trim()
        if (-not $p) { continue }
        $key = $p.TrimEnd('\').ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $parts += $p
    }
    $env:Path = ($parts -join ';')
}

# ---------------------------------------------------- debloat tool (Win11Debloat)
function Get-DebloatTool {
    # Downloads the latest Win11Debloat release, verifies its SHA-256 when the
    # release publishes one, unpacks it into %LOCALAPPDATA%\win-setup\Win11Debloat
    # and returns the path to Win11Debloat.ps1 ($null on failure).
    $dir  = Join-Path $script:StateDir 'Win11Debloat'
    $main = Join-Path $dir 'Win11Debloat.ps1'
    $zip  = Join-Path $env:TEMP 'win11debloat.zip'
    $sums = Join-Path $env:TEMP 'win11debloat.sha256sums'
    $expected = $null

    try {
        $rel = Invoke-RestMethod -Uri ("https://api.github.com/repos/{0}/releases/latest" -f $CONFIG.Debloat.Repo) -UseBasicParsing
        $uri = $rel.zipball_url
        $archiveAsset   = @($rel.assets | Where-Object { $_.name -ceq 'Win11Debloat.zip' }) | Select-Object -First 1
        $checksumsAsset = @($rel.assets | Where-Object { $_.name -ceq 'SHA256SUMS' }) | Select-Object -First 1

        if ($archiveAsset -and $checksumsAsset) {
            Invoke-WebRequest -Uri $checksumsAsset.browser_download_url -OutFile $sums -UseBasicParsing -ErrorAction Stop
            foreach ($line in ((Get-Content -LiteralPath $sums) -split "`r?`n")) {
                if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -ceq 'Win11Debloat.zip') {
                    $expected = $Matches[1].ToLowerInvariant()
                }
            }
            Remove-Item -LiteralPath $sums -Force -ErrorAction SilentlyContinue
            if (-not $expected) { throw 'SHA256SUMS does not list Win11Debloat.zip' }
            $uri = $archiveAsset.browser_download_url
        } else {
            Write-Log 'release publishes no checksum - downloading the source archive' 'WARN'
        }

        Write-Log 'downloading Win11Debloat'
        Invoke-WebRequest -Uri $uri -OutFile $zip -UseBasicParsing -ErrorAction Stop
    } catch {
        if (Test-Path -LiteralPath $main) {
            Write-Log ("download failed ({0}) - using the cached copy" -f $_.Exception.Message) 'WARN'
            return $main
        }
        Write-Log ("could not download Win11Debloat: {0}" -f $_.Exception.Message) 'FAIL'
        return $null
    }

    if ($expected) {
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            Write-Log 'Win11Debloat archive does not match the published checksum - not running it' 'FAIL'
            return $null
        }
        Write-Log 'Win11Debloat checksum OK' 'OK'
    }

    $unpack = Join-Path $env:TEMP 'win11debloat-unpack'
    if (Test-Path -LiteralPath $unpack) { Remove-Item -LiteralPath $unpack -Recurse -Force }
    try {
        Expand-Archive -LiteralPath $zip -DestinationPath $unpack -Force -ErrorAction Stop
    } catch {
        Write-Log ("could not unpack Win11Debloat: {0}" -f $_.Exception.Message) 'FAIL'
        return $null
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }

    $found = Get-ChildItem -LiteralPath $unpack -Recurse -Filter 'Win11Debloat.ps1' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $found) {
        Write-Log 'archive does not contain Win11Debloat.ps1' 'FAIL'
        return $null
    }

    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    Move-Item -LiteralPath $found.Directory.FullName -Destination $dir
    Remove-Item -LiteralPath $unpack -Recurse -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath $main)) {
        Write-Log 'Win11Debloat.ps1 is missing after unpacking' 'FAIL'
        return $null
    }
    Write-Log ("Win11Debloat ready at {0}" -f $dir) 'OK'
    return $main
}

function Invoke-Win11Debloat {
    param([string]$ScriptPath, [string[]]$Arguments)
    # Win11Debloat ends with `Exit`, so it has to run in its own process.
    # This process is already elevated, therefore no second UAC prompt appears.
    # `| Out-Host` keeps its stdout out of our return value: without it the
    # function returned an array of output lines instead of the exit code.
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $Arguments = @($Arguments) + @('-LogPath', $script:StateDir)
    & $exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments | Out-Host
    if ($null -eq $LASTEXITCODE) { return -1 }
    return [int]$LASTEXITCODE
}

# ------------------------------------------- remote access and startup helpers
function Resolve-Python {
    # The Store alias python.exe is a stub that fails, so prefer the launcher
    # and real installs over whatever "python" resolves to first.
    $launcher = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($launcher) {
        try {
            $exe = & $launcher.Source -3 -c "import sys;print(sys.executable)" 2>$null | Select-Object -First 1
            if ($exe -and (Test-Path -LiteralPath $exe)) { return $exe }
        } catch { }
    }
    foreach ($root in @('C:\Program Files', (Join-Path $env:LOCALAPPDATA 'Programs\Python'))) {
        foreach ($dir in @(Get-ChildItem -Path $root -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
            $exe = Join-Path $dir.FullName 'python.exe'
            if (Test-Path -LiteralPath $exe) { return $exe }
        }
    }
    $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        try { & $cmd.Source --version *> $null; if ($LASTEXITCODE -eq 0) { return $cmd.Source } } catch { }
    }
    return $null
}

function Find-T3CodeExe {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\t3code\T3 Code (Nightly).exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\t3code\T3 Code.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\T3 Code\T3 Code.exe'),
        (Join-Path $env:ProgramFiles 'T3 Code\T3 Code.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'T3 Code\T3 Code.exe')
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    foreach ($root in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                      'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                      'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') {
        foreach ($e in @(Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
                         Where-Object { $_.DisplayName -like 'T3 Code*' -and $_.DisplayIcon })) {
            $p = ($e.DisplayIcon -split ',')[0].Trim().Trim('"')
            if ($p -and (Test-Path -LiteralPath $p)) { return $p }
        }
    }
    return $null
}

function Resolve-Pwsh {
    # PowerShell 7 may be an MSI (Program Files\PowerShell\7) or an MSIX with an
    # app-execution alias in WindowsApps; the alias is the only usable path there.
    $candidates = @()
    $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    $candidates += @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'),
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        (Join-Path $env:ProgramFiles 'PowerShell\7-preview\pwsh.exe')
    )
    foreach ($c in $candidates) {
        if (-not $c -or -not (Test-Path -LiteralPath $c)) { continue }
        try {
            $major = & $c -NoProfile -Command '$PSVersionTable.PSVersion.Major' 2>$null | Select-Object -First 1
            if ("$major" -match '^\d+$' -and [int]$major -ge 7) { return $c }
        } catch { }
    }
    return $null
}

function Install-TightVnc {
    param([int]$Port)

    $svc = Get-Service -Name 'tvnserver' -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Log 'TightVNC already installed' 'SKIP'
        return $true
    }
    if ($WhatIfOnly) { Write-Log ("would install TightVNC (loopback only, no password, port {0})" -f $Port); return $true }
    if (-not $winget) { Write-Log 'winget unavailable - cannot install TightVNC' 'FAIL'; return $false }

    # Property names verified against the 2.8.90 MSI ("SET_*" + "VALUE_OF_*" pairs).
    # SET_USEVNCAUTHENTICATION=1 "apply this setting", VALUE_OF_...=0 "value is off".
    $msiArgs = '/quiet ADDLOCAL=Server SERVER_REGISTER_AS_SERVICE=1 SERVER_ADD_FIREWALL_EXCEPTION=0 ' +
               'SET_RFBPORT=1 VALUE_OF_RFBPORT={0} ' +
               'SET_LOOPBACKONLY=1 VALUE_OF_LOOPBACKONLY=1 ' +
               'SET_USEVNCAUTHENTICATION=1 VALUE_OF_USEVNCAUTHENTICATION=0 ' +
               'SET_RUNCONTROLINTERFACE=0'
    $msiArgs = $msiArgs -f $Port

    Write-Log 'installing TightVNC (loopback only, no password)'
    & $winget install --id 'GlavSoft.TightVNC' --exact --source winget --accept-package-agreements `
        --accept-source-agreements --disable-interactivity --override $msiArgs | Out-Null

    Start-Sleep -Seconds 2
    $svc = Get-Service -Name 'tvnserver' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log 'TightVNC service not found after install - install it manually and re-run' 'FAIL'
        [void]$script:Failed.Add('TightVNC')
        return $false
    }
    Start-Service -Name 'tvnserver' -ErrorAction SilentlyContinue
    Write-Log 'TightVNC service registered and running' 'OK'

    # The MSI property and the registry value do not always agree across builds,
    # so switch VNC authentication off directly and reload the service.
    $key = 'HKLM:\SOFTWARE\TightVNC\Server'
    if (Test-Path -LiteralPath $key) {
        foreach ($name in 'UseVncAuthentication', 'UseControlAuthentication') {
            $props = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).PSObject.Properties.Name
            if ($props -contains $name) {
                Set-ItemProperty -LiteralPath $key -Name $name -Value 0 -Type DWord -Force
            }
        }
        Restart-Service -Name 'tvnserver' -Force -ErrorAction SilentlyContinue
        $auth = (Get-ItemProperty -LiteralPath $key -Name 'UseVncAuthentication' -ErrorAction SilentlyContinue).UseVncAuthentication
        if ("$auth" -eq '0') { Write-Log 'TightVNC authentication is off (no password)' 'OK' }
        elseif ($null -eq $auth) { Write-Log 'could not verify the TightVNC auth setting - check TightVNC Server' 'WARN' }
        else { Write-Log 'TightVNC still asks for a password - turn off "Require VNC authentication" in TightVNC Server' 'WARN' }
    } else {
        Write-Log 'TightVNC registry key not found - check the password setting in TightVNC Server' 'WARN'
    }

    try {
        $listen = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty LocalAddress -Unique)
        if ($listen.Count -gt 0 -and -not ($listen -contains '127.0.0.1')) {
            Write-Log ("TightVNC listens on {0} - loopback-only did not apply" -f ($listen -join ', ')) 'WARN'
        } elseif ($listen.Count -gt 0) {
            Write-Log 'TightVNC listening on loopback only' 'OK'
        }
    } catch { }
    return $true
}

function Setup-NoVnc {
    param([int]$WebPort, [int]$VncPort)

    $base    = Join-Path $env:ProgramData 'win-setup\novnc'
    $web     = Join-Path $base 'web'
    $venv    = Join-Path $base 'venv'
    $wrapper = Join-Path $base 'start-novnc.ps1'
    $urlFile = Join-Path $base 'url.txt'
    $taskName = 'win-setup noVNC'

    if ($WhatIfOnly) {
        Write-Log ("would set up noVNC at {0} (websockify -> 127.0.0.1:{1})" -f $WebPort, $VncPort)
        Write-Log 'would create the startup task "win-setup noVNC"'
        return
    }

    if (-not (Test-Path -LiteralPath $base)) { New-Item -ItemType Directory -Path $base -Force | Out-Null }

    $py = Resolve-Python
    if (-not $py) {
        Write-Log 'python not found - cannot install websockify, noVNC skipped' 'FAIL'
        [void]$script:Failed.Add('noVNC (python)')
        return
    }

    if (-not (Test-Path -LiteralPath (Join-Path $venv 'Scripts\python.exe'))) {
        Write-Log 'creating the websockify virtualenv'
        & $py -m venv $venv *> $null
    }
    $venvPy = Join-Path $venv 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $venvPy)) {
        Write-Log 'could not create the virtualenv' 'FAIL'
        [void]$script:Failed.Add('noVNC (venv)')
        return
    }

    if (-not (Test-Path -LiteralPath (Join-Path $venv 'Scripts\websockify.exe'))) {
        Write-Log 'installing websockify'
        & $venvPy -m pip install --quiet --disable-pip-version-check websockify *> $null
    }
    $wsExe = Join-Path $venv 'Scripts\websockify.exe'
    if (-not (Test-Path -LiteralPath $wsExe)) {
        Write-Log 'websockify install failed' 'FAIL'
        [void]$script:Failed.Add('noVNC (websockify)')
        return
    }
    Write-Log 'websockify ready' 'OK'

    if (-not (Test-Path -LiteralPath (Join-Path $web 'vnc.html'))) {
        $zip = Join-Path $env:TEMP 'novnc.zip'
        # Unpack inside the destination, not in %TEMP%: a directory moved across
        # folders on the same volume keeps the source ACL, and %TEMP% is
        # user-only - which is exactly what made SYSTEM hit "Access is denied".
        $unpack = Join-Path $base '.unpack'
        try {
            $uri = 'https://github.com/novnc/noVNC/archive/refs/tags/v{0}.zip' -f $CONFIG.Remote.NoVncVersion
            Write-Log ("downloading noVNC {0}" -f $CONFIG.Remote.NoVncVersion)
            Invoke-WebRequest -Uri $uri -OutFile $zip -UseBasicParsing -ErrorAction Stop
            if (Test-Path -LiteralPath $unpack) { Remove-Item -LiteralPath $unpack -Recurse -Force }
            Expand-Archive -LiteralPath $zip -DestinationPath $unpack -Force -ErrorAction Stop
            $child = Get-ChildItem -LiteralPath $unpack -Directory | Select-Object -First 1
            if (-not $child) { throw 'archive is empty' }
            if (Test-Path -LiteralPath $web) { Remove-Item -LiteralPath $web -Recurse -Force }
            Move-Item -LiteralPath $child.FullName -Destination $web
            Write-Log 'noVNC files ready' 'OK'
        } catch {
            Write-Log ("could not download noVNC: {0}" -f $_.Exception.Message) 'FAIL'
            [void]$script:Failed.Add('noVNC (download)')
            return
        } finally {
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $unpack -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Belt and braces: reset ACLs so the whole tree inherits from ProgramData
    # (SYSTEM must be able to read the web root when the task runs).
    & icacls.exe $base /reset /T /C *> $null

    # websockify serves index.html for "/" (SimpleHTTPRequestHandler), and noVNC
    # ships none - without this the bare URL is a 404.
    $indexHtml = @'
<!DOCTYPE html>
<html>
<head><meta charset="utf-8" /><title>noVNC</title></head>
<body>
<p>Redirecting to <a href="vnc.html?autoconnect=true&amp;resize=scale">vnc.html</a>...</p>
<script>
  var q = location.search ? location.search.substring(1) : '';
  location.replace('vnc.html' + (q ? '?' + q : '?autoconnect=true&resize=scale'));
</script>
</body>
</html>
'@
    [IO.File]::WriteAllText((Join-Path $web 'index.html'), $indexHtml, (New-Object System.Text.UTF8Encoding($false)))

    # Where may websockify listen? The Tailscale address, and nothing else.
    $tsExe = $null
    $tsCmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($tsCmd) { $tsExe = $tsCmd.Source }
    if (-not $tsExe -and (Test-Path 'C:\Program Files\Tailscale\tailscale.exe')) { $tsExe = 'C:\Program Files\Tailscale\tailscale.exe' }

    $tailIp = $null
    $tailName = $null
    if ($tsExe) {
        try { $tailIp = @(& $tsExe ip -4 2>$null | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })[0] } catch { }
        try {
            $status = (& $tsExe status --json 2>$null | Out-String | ConvertFrom-Json)
            if ($status.Self -and $status.Self.DNSName) { $tailName = ([string]$status.Self.DNSName).TrimEnd('.') }
        } catch { }
    }
    if (-not $tailIp) {
        Write-Log 'Tailscale is not up - noVNC will only listen on localhost until the next start' 'WARN'
    }

    $urlHost = $tailIp
    if ($tailName) { $urlHost = $tailName }
    $url = 'http://{0}:{1}/' -f $urlHost, $WebPort
    $script:NoVncUrl = $url

    $wrapperText = @'
<#
    Starts websockify (the noVNC proxy) on the Tailscale address.
    Installed by win-setup.ps1 - runs from Task Scheduler as SYSTEM at boot.
#>
$ErrorActionPreference = 'Continue'
$log = '__LOG__'
$ts  = '__TS__'
$ip  = $null
for ($i = 0; $i -lt 60; $i++) {
    try { $ip = @(& $ts ip -4 2>$null | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })[0] } catch { }
    if ($ip) { break }
    Start-Sleep -Seconds 5
}
if (-not $ip) { $ip = '127.0.0.1' }
Add-Content -LiteralPath $log -Value ("{0}  websockify on {1}:__PORT__ -> 127.0.0.1:__VNC__" -f (Get-Date -Format 's'), $ip)
& '__WS__' --web '__WEB__' ("{0}:__PORT__" -f $ip) '127.0.0.1:__VNC__' *>> $log
exit $LASTEXITCODE
'@
    $wrapperText = $wrapperText.Replace('__LOG__', (Join-Path $base 'novnc.log'))
    $wrapperText = $wrapperText.Replace('__TS__', $(if ($tsExe) { $tsExe } else { 'tailscale.exe' }))
    $wrapperText = $wrapperText.Replace('__WS__', $wsExe)
    $wrapperText = $wrapperText.Replace('__WEB__', $web)
    $wrapperText = $wrapperText.Replace('__PORT__', "$WebPort")
    $wrapperText = $wrapperText.Replace('__VNC__', "$VncPort")
    [IO.File]::WriteAllText($wrapper, $wrapperText, (New-Object System.Text.UTF8Encoding($false)))
    Write-Log 'websockify launcher written' 'OK'

    # Firewall: allow the web port from the tailnet only, block raw VNC from everywhere.
    try {
        Get-NetFirewallRule -DisplayName 'win-setup noVNC (tailnet)' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        New-NetFirewallRule -DisplayName 'win-setup noVNC (tailnet)' -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort $WebPort -RemoteAddress '100.64.0.0/10' -Profile Any | Out-Null
        Get-NetFirewallRule -DisplayName 'win-setup VNC block' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        New-NetFirewallRule -DisplayName 'win-setup VNC block' -Direction Inbound -Action Block `
            -Protocol TCP -LocalPort $VncPort -Profile Any | Out-Null
        Write-Log 'firewall: web port open to the tailnet, VNC port blocked' 'OK'
    } catch {
        Write-Log ("could not set firewall rules: {0}" -f $_.Exception.Message) 'FAIL'
        [void]$script:Failed.Add('noVNC (firewall)')
    }

    # Start at boot, no user session needed.
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $wrapper)
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings | Out-Null
        Start-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Write-Log 'startup task "win-setup noVNC" registered' 'OK'
    } catch {
        Write-Log ("could not register the startup task: {0}" -f $_.Exception.Message) 'FAIL'
        [void]$script:Failed.Add('noVNC (task)')
    }

    # The first version kept the stack in the user profile, which SYSTEM cannot
    # read (websockify failed with Access is denied). Drop that copy.
    $legacy = Join-Path $script:StateDir 'novnc'
    if ((Test-Path -LiteralPath $legacy) -and ($legacy -ne $base)) {
        Remove-Item -LiteralPath $legacy -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log 'removed the old per-user noVNC copy' 'OK'
    }

    # Probe locally so a broken proxy is reported now, not when you open the URL.
    $probeHost = $tailIp
    if (-not $probeHost) { $probeHost = '127.0.0.1' }
    $probeUrl = 'http://{0}:{1}/vnc.html' -f $probeHost, $WebPort
    $alive = $false
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Milliseconds 1500
        try {
            $resp = Invoke-WebRequest -Uri $probeUrl -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            if ($resp.StatusCode -eq 200) { $alive = $true; break }
        } catch { }
    }
    if ($alive) {
        Write-Log ("noVNC answers at {0}" -f $probeUrl) 'OK'
    } else {
        Write-Log ("noVNC does not answer at {0} - check {1}" -f $probeUrl, (Join-Path $base 'novnc.log')) 'FAIL'
        [void]$script:Failed.Add('noVNC (not answering)')
    }

    Set-Content -LiteralPath $urlFile -Value $url -Encoding ASCII
}

function Set-T3CodeAutostart {
    $dir      = Join-Path $script:StateDir 'T3CodeStartup'
    $launcher = Join-Path $dir 'start-t3code-minimized.ps1'
    $startup  = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    $lnkPath  = Join-Path $startup 'T3 Code (minimized).lnk'

    if ($WhatIfOnly) {
        Write-Log 'would add the "T3 Code (minimized)" autostart shortcut'
        return
    }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $startup)) { New-Item -ItemType Directory -Path $startup -Force | Out-Null }

    $launcherText = @'
<#
    Starts T3 Code at login and minimizes its main window.
    Installed by win-setup.ps1. T3 Code has no built-in "start minimized".
#>
param([int]$WatchSeconds = 90)
$ErrorActionPreference = 'Stop'
$logFile = Join-Path $env:LOCALAPPDATA 'win-setup\T3CodeStartup\startup.log'

function Write-StartupLog {
    param([string]$Message)
    try { Add-Content -LiteralPath $logFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8 } catch { }
}

function Find-T3CodeExe {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\t3code\T3 Code (Nightly).exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\t3code\T3 Code.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\T3 Code\T3 Code.exe'),
        (Join-Path $env:ProgramFiles 'T3 Code\T3 Code.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'T3 Code\T3 Code.exe')
    )
    foreach ($p in $candidates) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    foreach ($root in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                      'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                      'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') {
        foreach ($e in @(Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
                         Where-Object { $_.DisplayName -like 'T3 Code*' -and $_.DisplayIcon })) {
            $p = ($e.DisplayIcon -split ',')[0].Trim().Trim('"')
            if ($p -and (Test-Path -LiteralPath $p)) { return $p }
        }
    }
    return $null
}

$exe = Find-T3CodeExe
if (-not $exe) { Write-StartupLog 'T3 Code executable not found'; exit 1 }

$procName = [System.IO.Path]::GetFileNameWithoutExtension($exe)
$running = @(Get-Process -Name $procName -ErrorAction SilentlyContinue |
             Where-Object { $_.Path -and $_.Path -eq $exe })
if ($running.Count -gt 0) { Write-StartupLog 'T3 Code already running; leaving it alone'; exit 0 }

try {
    $started = Start-Process -FilePath $exe -PassThru
    Write-StartupLog ("Started T3 Code (PID {0})" -f $started.Id)
} catch {
    Write-StartupLog ("Failed to start T3 Code: {0}" -f $_.Exception.Message)
    exit 1
}

if (-not ('T3Win' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class T3Win
{
    private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);
    [DllImport("user32.dll")] private static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    private struct RECT { public int L, T, R, B; }

    public static int Minimize(uint[] pids, int minW, int minH)
    {
        var set = new HashSet<uint>(pids);
        int count = 0;
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if (!set.Contains(pid)) return true;
            if (!IsWindowVisible(hWnd) || IsIconic(hWnd)) return true;
            if (GetWindow(hWnd, 4) != IntPtr.Zero) return true;
            if (GetWindowTextLength(hWnd) == 0) return true;
            RECT r;
            if (GetWindowRect(hWnd, out r))
            {
                if ((r.R - r.L) >= minW && (r.B - r.T) >= minH)
                {
                    if (ShowWindow(hWnd, 6)) count++;
                }
            }
            return true;
        }, IntPtr.Zero);
        return count;
    }
}
"@
}

$deadline = (Get-Date).AddSeconds($WatchSeconds)
$done = $false
while (-not $done -and (Get-Date) -lt $deadline) {
    $pids = @(Get-Process -Name $procName -ErrorAction SilentlyContinue |
              Where-Object { $_.Path -and $_.Path -eq $exe } |
              Select-Object -ExpandProperty Id)
    if ($pids.Count -gt 0) {
        $n = [T3Win]::Minimize([uint32[]]$pids, 500, 350)
        if ($n -gt 0) {
            Write-StartupLog ("Minimized {0} window(s)" -f $n)
            Start-Sleep -Seconds 3
            [void][T3Win]::Minimize([uint32[]]$pids, 500, 350)
            $done = $true
        }
    }
    Start-Sleep -Milliseconds 250
}
if (-not $done) { Write-StartupLog 'T3 Code main window did not appear in time' }
exit 0
'@

    [IO.File]::WriteAllText($launcher, $launcherText, (New-Object System.Text.UTF8Encoding($false)))

    $exe = Find-T3CodeExe
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($lnkPath)
    $lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $launcher
    $lnk.WorkingDirectory = $dir
    $lnk.WindowStyle = 7
    $lnk.Description = 'Start T3 Code minimized'
    if ($exe) { $lnk.IconLocation = ('{0},0' -f $exe) }
    $lnk.Save()

    if ($exe) { Write-Log 'T3 Code autostart (minimized) installed' 'OK' }
    else { Write-Log 'T3 Code autostart installed, but the exe was not found yet' 'WARN' }
}

# ------------------------------------------------------------ options ----
$opt = [ordered]@{
    Debloat        = (-not $NoDebloat)
    Aggressive     = [bool]$Aggressive
    Optional       = (-not $NoOptional)
    RestorePoint   = (-not $NoRestorePoint)
    RemoveOneDrive = [bool]$RemoveOneDrive
    Remote         = (([bool]$CONFIG.Remote.EnableNoVNC) -and (-not $NoRemote))
    AutostartT3Code = (([bool]$CONFIG.Autostart.T3Code) -and (-not $NoT3Autostart))
    OnlyRemote     = [bool]$OnlyRemote
    Reboot         = [bool]$Reboot
    GitUserName    = $GitUserName
    GitUserEmail   = $GitUserEmail
}

# A relaunched (elevated) child gets its choices from a JSON file, never from
# quoted command-line strings - no escaping bugs, no lost switches.
if ($Answers -and (Test-Path -LiteralPath $Answers)) {
    try {
        $saved = Get-Content -LiteralPath $Answers -Raw | ConvertFrom-Json
        foreach ($name in @($saved.PSObject.Properties.Name)) {
            if ($opt.Contains($name)) { $opt[$name] = $saved.$name }
        }
    } catch {
        Write-Host ("could not read answers file {0}: {1}" -f $Answers, $_.Exception.Message) -ForegroundColor Yellow
    }
}

if (-not $opt.GitUserName)  { $opt.GitUserName  = $CONFIG.Git.UserName }
if (-not $opt.GitUserEmail) { $opt.GitUserEmail = $CONFIG.Git.UserEmail }

# -OnlyRemote: rebuild just the remote stack (and its autostart), nothing else.
if ($opt.OnlyRemote) {
    $opt.Debloat         = $false
    $opt.Optional        = $false
    $opt.RestorePoint    = $false
    $opt.Remote          = $true
    $opt.AutostartT3Code = $true
}

# Nothing to undo? Say it before bothering with UAC.

# ----------------------------------------------------------------- menu ----
if (-not $Revert -and -not $Yes -and -not $Answers -and -not $WhatIfOnly -and -not $opt.OnlyRemote -and (Test-CanPrompt)) {
    Write-Host ''
    Write-Host '  What should happen? ENTER keeps the [DEFAULT].' -ForegroundColor White
    Write-Host ''
    $opt.Debloat = Read-YesNo '  debloat Windows (bundled apps, telemetry, ads)' $opt.Debloat
    if ($opt.Debloat) {
        $opt.Aggressive = Read-YesNo '    aggressive (Copilot, Recall, widgets, Xbox bar, location)' $opt.Aggressive
    }
    $opt.Optional = Read-YesNo '  install optional group (Chrome, VS 2022, Claude Desktop...)' $opt.Optional
    $opt.RestorePoint = Read-YesNo '  create a restore point first' $opt.RestorePoint
    $opt.RemoveOneDrive = Read-YesNo '  remove OneDrive completely' $opt.RemoveOneDrive
    $opt.Remote = Read-YesNo '  remote access: noVNC over Tailscale (TightVNC)' $opt.Remote
    $opt.AutostartT3Code = Read-YesNo '  start T3 Code minimized at login' $opt.AutostartT3Code
    if (Read-YesNo '  set git user.name / user.email now' $true) {
        $opt.GitUserName  = Read-Text '    git user.name'  $opt.GitUserName
        $opt.GitUserEmail = Read-Text '    git user.email' $opt.GitUserEmail
    }
    $opt.Reboot = Read-YesNo '  reboot when finished' $opt.Reboot
    Write-Host ''
}

# -------------------------------------------------------------- elevation --
if (-not (Test-IsAdmin) -and -not $WhatIfOnly) {
    $self = $script:SelfPath

    # `irm | iex`: no file on disk, so fetch a copy of ourselves first.
    if (-not $self) {
        $url = $SourceUrl
        if ($env:WIN_SETUP_URL) { $url = $env:WIN_SETUP_URL }
        if (-not $url -or $url -match 'USER/REPO') {
            Write-Host ''
            Write-Host '  This script must run as administrator, but it was pasted with' -ForegroundColor Yellow
            Write-Host '  "irm | iex" so there is no local file to relaunch.' -ForegroundColor Yellow
            Write-Host '  Either fill in $SourceUrl at the top of the script, or run:' -ForegroundColor Yellow
            Write-Host ''
            Write-Host '    irm <url> -OutFile "$env:TEMP\win-setup.ps1"' -ForegroundColor White
            Write-Host '    Start-Process powershell -Verb RunAs -ArgumentList ''-NoProfile'',''-ExecutionPolicy'',''Bypass'',''-File'',''"$env:TEMP\win-setup.ps1"''' -ForegroundColor White
            Write-Host ''
            exit 1
        }
        $self = Join-Path $script:StateDir 'win-setup.ps1'
        Write-Host '  Downloading a local copy of the script...' -ForegroundColor Yellow
        try {
            Invoke-WebRequest -Uri $url -OutFile $self -UseBasicParsing -ErrorAction Stop
        } catch {
            Write-Host ("  download failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
            Write-Host ("  source: {0}" -f $url) -ForegroundColor Red
            exit 1
        }
        Write-Host ("  saved to {0}" -f $self) -ForegroundColor DarkGray
    }

    try {
        $opt | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $script:AnswersFile -Encoding UTF8
    } catch { }

    Write-Host ''
    Write-Host '  Relaunching as administrator (accept the UAC prompt)...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $self),
                 '-Answers', ('"{0}"' -f $script:AnswersFile), '-Pause')
    if ($Force) { $argList += '-Force' }
    if ($Revert) { $argList += '-Revert' }

    try {
        $proc = Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $argList -Wait -PassThru
    } catch {
        Write-Host ("  elevation cancelled or failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
    Write-Host ''
    Write-Host ("  finished - logs and backup: {0}" -f $script:StateDir) -ForegroundColor DarkGray
    if ($proc) { exit $proc.ExitCode }
    exit 0
}

# ==========================================================================
# ==========================================================================
#  MODE: revert - Win11Debloat's own restore window
# ==========================================================================
if ($Revert) {
    if ($WhatIfOnly) {
        Write-Host 'DRY RUN: would open the Win11Debloat restore window' -ForegroundColor Yellow
        exit 0
    }
    $debloatScript = Get-DebloatTool
    if (-not $debloatScript) { exit 1 }

    Write-Host ''
    Write-Host '  Opening Win11Debloat. Pick "Restore backup" there.' -ForegroundColor Yellow
    Write-Host ("  Backups: {0}" -f (Join-Path $env:LOCALAPPDATA 'Win11Debloat\Backups')) -ForegroundColor DarkGray
    Write-Host ''
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $debloatScript) | Out-Null
    exit 0
}

# ----------------------------------------------------------------- banner --
$started = Get-Date
Write-Host ''
Write-Host '==========================================================' -ForegroundColor White
Write-Host '  win-setup: debloat + developer toolchain' -ForegroundColor White
Write-Host ('  {0} | {1}' -f $env:COMPUTERNAME, $(if ($WhatIfOnly) { 'DRY RUN' } else { (Get-Date -Format 'yyyy-MM-dd HH:mm') })) -ForegroundColor DarkGray
Write-Host '==========================================================' -ForegroundColor White
Write-Log ("log: {0}" -f $script:LogFile)
Write-Log ("debloat: {0} (aggressive: {1}) | optional: {2} | restore point: {3} | remote: {4} | t3 autostart: {5} | reboot: {6}" -f `
    $opt.Debloat, $opt.Aggressive, $opt.Optional, $opt.RestorePoint, $opt.Remote, $opt.AutostartT3Code, $opt.Reboot)

$os = Get-CimInstance Win32_OperatingSystem
if ([int]$os.BuildNumber -lt 22000) { Write-Log 'optimised for Windows 11; older builds may differ' 'WARN' }
if ($os.Caption -match 'Evaluation') { Write-Log 'Windows Evaluation edition - it expires, plan a licensed reinstall' 'WARN' }

# ---------------------------------------------------------------- preflight --
function Test-Endpoint {
    param([string]$HostName, [int]$Port = 443)
    try {
        return (Test-NetConnection -ComputerName $HostName -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue)
    } catch { return $false }
}

if (-not $WhatIfOnly) {
    Write-Log 'preflight' 'STEP'
    if (-not (Test-Endpoint 'api.github.com')) {
        Write-Log 'no HTTPS access to github.com - the debloat download will fail' 'FAIL'
    }
    if (-not (Test-Endpoint 'cdn.winget.microsoft.com')) {
        Write-Log 'no HTTPS access to the winget CDN - package installs will fail' 'FAIL'
    }
    $sysDrive = $env:SystemDrive.TrimEnd(':')
    try {
        $freeGB = (Get-PSDrive -Name $sysDrive -ErrorAction Stop).Free / 1GB
        if ($freeGB -lt 15) {
            Write-Log ("only {0:N1} GB free on {1}: - Visual Studio wants ~20 GB" -f $freeGB, $env:SystemDrive) 'WARN'
        } else {
            Write-Log ("free space: {0:N1} GB" -f $freeGB)
        }
    } catch { }
}

# ==========================================================================
# ==========================================================================
#  PHASE 1 - debloat (delegated to Win11Debloat)
# ==========================================================================
if ($opt.Debloat) {
    Write-Log 'PHASE 1/4 - debloat (Win11Debloat)' 'STEP'

    $debloatArgs = @($CONFIG.Debloat.BaseArgs) + @($CONFIG.Debloat.PersonalArgs)
    if ($opt.RestorePoint) { $debloatArgs += '-CreateRestorePoint' }
    if ($opt.Aggressive)   { $debloatArgs += @($CONFIG.Debloat.AggressiveArgs) }

    if ($WhatIfOnly) {
        Write-Log ("would run Win11Debloat {0}" -f ($debloatArgs -join ' '))
    } else {
        $debloatScript = Get-DebloatTool
        if ($debloatScript) {
            Write-Log ("running Win11Debloat {0}" -f ($debloatArgs -join ' '))
            $debloatExit = Invoke-Win11Debloat -ScriptPath $debloatScript -Arguments $debloatArgs
            if ($debloatExit -eq 0) {
                Write-Log 'Win11Debloat finished' 'OK'
            } else {
                Write-Log ("Win11Debloat exited with code {0}" -f $debloatExit) 'FAIL'
                [void]$script:Failed.Add("Win11Debloat (exit $debloatExit)")
            }
        }
    }

    if ($opt.RemoveOneDrive) {
        $setup = Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe'
        if (-not (Test-Path -LiteralPath $setup)) {
            Write-Log 'OneDrive setup not found' 'SKIP'
        } elseif ($WhatIfOnly) {
            Write-Log 'would uninstall OneDrive'
        } else {
            Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
            Start-Process -FilePath $setup -ArgumentList '/uninstall' -Wait
            Remove-Item "$env:LOCALAPPDATA\Microsoft\OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log 'OneDrive uninstalled' 'OK'
        }
    }
} else {
    Write-Log 'PHASE 1/4 - debloat skipped' 'SKIP'
}

# ==========================================================================
#  PHASE 2 - windows settings
# ==========================================================================
Write-Log 'PHASE 2/4 - windows settings' 'STEP'
$s = $CONFIG.Settings

if ($s.EnableLongPaths) {
    if ($WhatIfOnly) { Write-Log 'would enable long paths' }
    else {
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -Value 1 -Type DWord -Force
        Write-Log 'long paths enabled' 'OK'
    }
}
if ($s.EnableDeveloperMode) {
    if ($WhatIfOnly) { Write-Log 'would enable developer mode' }
    else {
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        Set-ItemProperty -Path $key -Name 'AllowDevelopmentWithoutDevLicense' -Value 1 -Type DWord -Force
        Write-Log 'developer mode enabled' 'OK'
    }
}
if ($s.ExecutionPolicy) {
    if ($WhatIfOnly) { Write-Log ("would set ExecutionPolicy to {0}" -f $s.ExecutionPolicy) }
    else {
        Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy $s.ExecutionPolicy -Force
        Write-Log ("ExecutionPolicy = {0}" -f $s.ExecutionPolicy) 'OK'
    }
}
if ($s.SetTimezone) {
    if ($WhatIfOnly) { Write-Log ("would set time zone to {0}" -f $s.SetTimezone) }
    else {
        try { Set-TimeZone -Id $s.SetTimezone; Write-Log ("time zone = {0}" -f $s.SetTimezone) 'OK' }
        catch { Write-Log ("unknown time zone {0}" -f $s.SetTimezone) 'WARN' }
    }
}

# ==========================================================================
#  PHASE 3 - packages
# ==========================================================================
function Resolve-Winget {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$winget = Resolve-Winget
if (-not $winget -and -not $WhatIfOnly) {
    Write-Log 'winget missing - installing App Installer from GitHub' 'WARN'
    try {
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -UseBasicParsing
        $asset = $rel.assets | Where-Object { $_.name -like '*DesktopAppInstaller*.msixbundle' } | Select-Object -First 1
        if (-not $asset) { throw 'no msixbundle in latest release' }
        $msix = Join-Path $env:TEMP $asset.name
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msix -UseBasicParsing
        Add-AppxPackage -Path $msix
        $winget = Resolve-Winget
        Write-Log 'App Installer installed' 'OK'
    } catch {
        Write-Log ("winget bootstrap failed: {0}" -f $_.Exception.Message) 'FAIL'
        Write-Log 'install "App Installer" from the Microsoft Store and re-run' 'FAIL'
    }
}

function Install-WingetPackage {
    param([string]$Id)
    if (-not $Force -and (Test-PackageInstalled -Id $Id)) {
        Write-Log ("skip  {0} (present)" -f $Id) 'SKIP'
        [void]$script:Results.Add([pscustomobject]@{ Id = $Id; Status = 'skipped' })
        return
    }
    if ($WhatIfOnly) {
        Write-Log ("would install {0}" -f $Id)
        [void]$script:Results.Add([pscustomobject]@{ Id = $Id; Status = 'planned' })
        return
    }
    if (-not $winget) { Write-Log 'winget unavailable' 'FAIL'; return }

    $base = @('install', '--id', $Id, '--exact', '--source', 'winget',
              '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    & $winget @base --silent | Out-Null
    if ($LASTEXITCODE -ne 0) { & $winget @base | Out-Null }   # some installers reject silent mode
    if ($LASTEXITCODE -eq 0) {
        Write-Log ("installed {0}" -f $Id) 'OK'
        [void]$script:Results.Add([pscustomobject]@{ Id = $Id; Status = 'installed' })
    } else {
        Write-Log ("FAILED {0} (exit {1})" -f $Id, $LASTEXITCODE) 'FAIL'
        [void]$script:Results.Add([pscustomobject]@{ Id = $Id; Status = 'failed' })
        [void]$script:Failed.Add("package: $Id")
    }
}

$script:InstalledCache = @{}
function Test-PackageInstalled {
    param([string]$Id)
    if ($script:InstalledCache.ContainsKey($Id)) { return $script:InstalledCache[$Id] }
    if (-not $winget) { return $false }
    # Locale-independent on purpose: `winget list` prints its "nothing found"
    # message in the OS language, so keying on English text breaks on a Polish
    # (or any non-English) Windows. The row is the only place the exact id
    # appears as a standalone token.
    $out = & $winget list --id $Id --exact --source winget --accept-source-agreements --disable-interactivity 2>&1 | Out-String
    $ok = $out -match ('(?<!\S)' + [regex]::Escape($Id) + '(?!\S)')
    $script:InstalledCache[$Id] = $ok
    return $ok
}

function Install-VisualStudio {
    $vs = $CONFIG.VisualStudio
    if (-not $vs -or -not $vs.ProductId) { return }
    if (-not $opt.Optional) {
        Write-Log 'Visual Studio skipped (it is part of the optional group)' 'SKIP'
        return
    }
    if (-not $Force -and (Test-PackageInstalled -Id $vs.ProductId)) {
        Write-Log ("skip  {0} (present)" -f $vs.ProductId) 'SKIP'
        return
    }
    $workloads = @($vs.Workloads | Where-Object { $_ } | Select-Object -Unique)
    if ($WhatIfOnly) { Write-Log ("would install {0} with {1} workload(s)" -f $vs.ProductId, $workloads.Count); return }
    if (-not $winget) { Write-Log 'winget unavailable' 'FAIL'; return }

    Write-Log ("installing {0} - this takes a while" -f $vs.ProductId)
    $override = '--quiet --wait --norestart'
    foreach ($w in $workloads) { $override += " --add $w" }
    if ($vs.IncludeRecommended) { $override += ' --includeRecommended' }

    & $winget install --id $vs.ProductId --exact --source winget --accept-package-agreements `
        --accept-source-agreements --disable-interactivity --override $override | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Log ("installed {0}" -f $vs.ProductId) 'OK'
    } else {
        Write-Log ("FAILED {0} (exit {1})" -f $vs.ProductId, $LASTEXITCODE) 'FAIL'
        [void]$script:Failed.Add("package: $($vs.ProductId)")
    }
}

Write-Log 'PHASE 3/4 - packages' 'STEP'

if ($winget -and -not $WhatIfOnly) {
    $wingetVersion = (& $winget --version 2>$null | Select-Object -First 1)
    if ($wingetVersion) {
        Write-Log ("winget {0}" -f $wingetVersion)
        $cleanVersion = ($wingetVersion -replace '^v', '').Trim()
        try {
            if ([version]$cleanVersion -lt [version]'1.6.0') {
                Write-Log 'winget is old - update "App Installer" from the Microsoft Store' 'WARN'
            }
        } catch { }
    }
    Write-Log 'refreshing winget sources'
    & $winget source update --disable-interactivity 2>&1 | Out-Null
}

$targets = New-Object System.Collections.Generic.List[string]
$coreList = @($CONFIG.Packages.Core)
if ($opt.OnlyRemote) { $coreList = @('Python.Python.3.15') }   # websockify needs it
foreach ($id in $coreList) { if ($id) { $targets.Add($id) } }
if ($opt.Optional) { foreach ($id in @($CONFIG.Packages.Optional)) { if ($id) { $targets.Add($id) } } }

$excluded = @($CONFIG.Packages.Excluded | Where-Object { $_ })
$vsProduct = $CONFIG.VisualStudio.ProductId
$targets = @($targets | Where-Object { $excluded -notcontains $_ -and $_ -ne $vsProduct } | Select-Object -Unique)

Write-Log ("{0} package(s) queued (optional: {1})" -f $targets.Count, $opt.Optional)
foreach ($id in $targets) { Install-WingetPackage -Id $id }
Install-VisualStudio

# winget just changed PATH for this user - pick the new entries up.
Update-SessionPath

if ($opt.Remote) {
    [void](Install-TightVnc -Port $CONFIG.Remote.VncPort)
} else {
    Write-Log 'TightVNC skipped (remote access is off)' 'SKIP'
}

# ==========================================================================
#  PHASE 4 - post-config
# ==========================================================================
Write-Log 'PHASE 4/4 - post-config' 'STEP'

$gitExe = $null
$gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue
if ($gitCmd) { $gitExe = $gitCmd.Source }
if (-not $gitExe -and (Test-Path 'C:\Program Files\Git\cmd\git.exe')) { $gitExe = 'C:\Program Files\Git\cmd\git.exe' }

if ($opt.OnlyRemote) {
    Write-Log 'git config skipped (only remote)' 'SKIP'
} elseif ($gitExe) {
    if ($WhatIfOnly) { Write-Log 'would configure git' }
    else {
        & $gitExe config --global init.defaultBranch $CONFIG.Git.DefaultBranch
        & $gitExe config --global core.autocrlf $CONFIG.Git.AutoCrlf
        & $gitExe config --global core.longpaths true
        & $gitExe config --global pull.rebase false
        & $gitExe config --global fetch.prune true
        if ($CONFIG.Git.Editor) { & $gitExe config --global core.editor $CONFIG.Git.Editor }
        if ($CONFIG.Git.CredentialHelper) { & $gitExe config --global credential.helper $CONFIG.Git.CredentialHelper }
        if ($opt.GitUserName)  { & $gitExe config --global user.name  $opt.GitUserName }
        if ($opt.GitUserEmail) { & $gitExe config --global user.email $opt.GitUserEmail }
        foreach ($alias in @($CONFIG.Git.Aliases.Keys)) {
            & $gitExe config --global ("alias.{0}" -f $alias) $CONFIG.Git.Aliases[$alias]
        }
        Write-Log 'git configured' 'OK'
        if (-not $opt.GitUserName -or -not $opt.GitUserEmail) {
            Write-Log 'git user.name / user.email are empty - set them in $CONFIG or at the prompt' 'WARN'
        }
    }
} else {
    Write-Log 'git not found (new PATH needs a new shell) - skipping git config' 'WARN'
}

# ---------------------------------------------------------------------- ssh --
$sshKey = Join-Path $env:USERPROFILE '.ssh\id_ed25519'
if ($opt.OnlyRemote) {
    # nothing to do
} elseif (-not $CONFIG.Git.GenerateSshKey) {
    # nothing to do
} elseif ($WhatIfOnly) {
    if (Test-Path -LiteralPath $sshKey) { Write-Log 'SSH key already present' 'SKIP' }
    else { Write-Log ("would create an ed25519 key at {0}" -f $sshKey) }
} elseif (Test-Path -LiteralPath $sshKey) {
    Write-Log 'SSH key already present' 'SKIP'
} else {
    $sshKeygen = $null
    $kg = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
    if ($kg) { $sshKeygen = $kg.Source }
    if (-not $sshKeygen -and (Test-Path 'C:\Program Files\Git\usr\bin\ssh-keygen.exe')) { $sshKeygen = 'C:\Program Files\Git\usr\bin\ssh-keygen.exe' }

    if (-not $sshKeygen) {
        Write-Log 'ssh-keygen not found - skipping SSH key' 'WARN'
    } else {
        $sshDir = Split-Path -Parent $sshKey
        if (-not (Test-Path -LiteralPath $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }
        $comment = $CONFIG.Git.SshKeyComment
        if (-not $comment) { $comment = $opt.GitUserEmail }
        if (-not $comment) { $comment = "$env:USERNAME@$env:COMPUTERNAME" }

        & $sshKeygen -t ed25519 -N '""' -C $comment -f $sshKey -q
        if (Test-Path -LiteralPath $sshKey) {
            Write-Log ("SSH key created: {0}" -f $sshKey) 'OK'
            # keep the private key private: no inheritance, only the current user
            $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            & icacls.exe $sshDir /inheritance:r /grant:r ("{0}:(OI)(CI)F" -f $me) *> $null

            try {
                Set-Service -Name ssh-agent -StartupType Automatic -ErrorAction Stop
                Start-Service -Name ssh-agent -ErrorAction SilentlyContinue
                & ssh-add.exe $sshKey *> $null
                Write-Log 'ssh-agent set to Automatic and key loaded' 'OK'
            } catch {
                Write-Log ("could not enable ssh-agent: {0}" -f $_.Exception.Message) 'WARN'
            }
        } else {
            Write-Log 'ssh-keygen did not produce a key' 'FAIL'
            [void]$script:Failed.Add('ssh key')
        }
    }
}

$pwshExe = Resolve-Pwsh

if ($pwshExe -and -not $opt.OnlyRemote) {
    foreach ($m in @($CONFIG.PostConfig.InstallPSModules)) {
        if (-not $m) { continue }
        if ($WhatIfOnly) { Write-Log "would install PS module $m"; continue }
        $cmd = "Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue; " +
               "if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) { Install-PackageProvider -Name NuGet -Scope CurrentUser -Force -ErrorAction SilentlyContinue | Out-Null }; " +
               "if (-not (Get-Module -ListAvailable '$m')) { Install-Module '$m' -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop }"
        & $pwshExe -NoProfile -Command $cmd *> $null
        if ($LASTEXITCODE -eq 0) { Write-Log ("PS module {0} ready" -f $m) 'OK' }
        else { Write-Log ("PS module {0} failed" -f $m) 'WARN' }
    }
} else {
    Write-Log 'pwsh not found - skipping PowerShell modules' 'WARN'
}

$bunExe = $null
$bunCmd = Get-Command bun.exe -ErrorAction SilentlyContinue
if ($bunCmd) { $bunExe = $bunCmd.Source }
if (-not $bunExe -and (Test-Path "$env:USERPROFILE\.bun\bin\bun.exe")) { $bunExe = "$env:USERPROFILE\.bun\bin\bun.exe" }

foreach ($pkg in @($CONFIG.PostConfig.BunGlobals)) {
    if (-not $pkg) { continue }
    if (-not $bunExe) { Write-Log 'bun not found - skipping bun globals' 'WARN'; break }
    if ($WhatIfOnly) { Write-Log "would install bun global $pkg"; continue }
    & $bunExe install -g $pkg *> $null
    if ($LASTEXITCODE -eq 0) { Write-Log ("bun global {0}" -f $pkg) 'OK' }
    else { Write-Log ("bun global {0} failed" -f $pkg) 'WARN' }
}

$npmExe = $null
$npmCmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
if ($npmCmd) { $npmExe = $npmCmd.Source }

foreach ($pkg in @($CONFIG.PostConfig.NpmGlobals)) {
    if (-not $pkg) { continue }
    if (-not $npmExe) { Write-Log 'npm not found - skipping npm globals' 'WARN'; break }
    if ($WhatIfOnly) { Write-Log "would install npm global $pkg"; continue }
    & $npmExe install -g $pkg --no-fund --no-audit *> $null
    if ($LASTEXITCODE -eq 0) { Write-Log ("npm global {0}" -f $pkg) 'OK' }
    else { Write-Log ("npm global {0} failed" -f $pkg) 'WARN' }
}

# -------------------------------------------------- remote access / startup --
if ($opt.Remote) {
    Setup-NoVnc -WebPort $CONFIG.Remote.WebPort -VncPort $CONFIG.Remote.VncPort
} else {
    Write-Log 'noVNC skipped' 'SKIP'
}

if ($opt.AutostartT3Code) {
    Set-T3CodeAutostart
} else {
    Write-Log 'T3 Code autostart skipped' 'SKIP'
}

# ==========================================================================
#  summary
# ==========================================================================
Write-Log 'summary' 'STEP'
if ($script:Results.Count -gt 0) {
    $ok      = @($script:Results | Where-Object Status -eq 'installed').Count
    $skipped = @($script:Results | Where-Object Status -eq 'skipped').Count
    $planned = @($script:Results | Where-Object Status -eq 'planned').Count
    $failedP = @($script:Results | Where-Object Status -eq 'failed').Count
    Write-Log ("packages: installed {0} | skipped {1} | planned {2} | failed {3}" -f $ok, $skipped, $planned, $failedP)
}
Write-Log ("debloat: Win11Debloat (log: {0})" -f (Join-Path $script:StateDir 'Win11Debloat.log'))
if ($script:Failed.Count -gt 0) {
    Write-Log ("{0} item(s) need attention:" -f $script:Failed.Count) 'FAIL'
    foreach ($f in $script:Failed) { Write-Log ("  - {0}" -f $f) 'FAIL' }
    Write-Log 'just run the script again - it is idempotent' 'WARN'
}
Write-Log ("log: {0}" -f $script:LogFile)
if ($WhatIfOnly) {
    Write-Log 'DRY RUN - nothing was changed' 'WARN'
} else {
    Write-Log 'done - reboot when convenient, then open a new terminal' 'WARN'
}

if (-not $WhatIfOnly -and $script:NoVncUrl) {
    Write-Host ''
    Write-Host '  noVNC (reachable from your tailnet only):' -ForegroundColor White
    Write-Host ('  ' + $script:NoVncUrl) -ForegroundColor DarkGray
    Write-Host ''
}

if (-not $WhatIfOnly -and (Test-Path -LiteralPath ($sshKey + '.pub'))) {
    Write-Host ''
    Write-Host '  SSH key ready. Add it to GitHub (Settings -> SSH and GPG keys):' -ForegroundColor White
    Write-Host ("  " + (Get-Content -LiteralPath ($sshKey + '.pub') -Raw).Trim()) -ForegroundColor DarkGray
    Write-Host '  Then: gh auth login   (or paste the key in the browser)' -ForegroundColor DarkGray
    Write-Host ''
}

if ($opt.Reboot -and -not $WhatIfOnly) {
    Write-Log 'rebooting in 15 seconds - press Ctrl+C to abort' 'WARN'
    Start-Sleep -Seconds 15
    Restart-Computer -Force
}

if ($Pause -and (Test-CanPrompt)) {
    Write-Host ''
    Read-Host 'Press ENTER to close' | Out-Null
}
