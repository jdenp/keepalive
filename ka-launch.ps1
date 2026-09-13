# keepalive core: run/attach any command in a tmux session that survives SSH disconnects.
#
# Usage:
#   ka <profile-or-command> [args...]   menu: attach to a running one, or start a new one
#   ka <x> -l    list sessions of x
#   ka <x> -n    start a new session (skip menu), optional args after
#   ka <x> -k    stop all sessions of x
#   ka           pick a profile (only if more than one hook profile exists)
#
# A "profile" is either a hooks/<name>/ folder (start.ps1 required, label.ps1 and
# stop.ps1 optional) or any ad-hoc command line wrapped in cmd.exe /c.
#
# Test seam: set KA_NO_MAIN=1 to dot-source this file for its functions only.

param([Parameter(ValueFromRemainingArguments = $true)] $All)

# keep EAP at Continue: native stderr under EAP=Stop becomes a terminating error
$script:HooksDir = $env:KA_HOOKS_DIR
if (-not $script:HooksDir) { $script:HooksDir = Join-Path $PSScriptRoot 'hooks' }
$script:PsExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
if (-not $script:PsExe) { $script:PsExe = 'powershell.exe' }

function Find-Tmux {
    $c = Get-Command tmux.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $link = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\tmux.exe'
    if (Test-Path -LiteralPath $link) { return $link }
    return $null
}

function Get-HookProfiles {
    if (-not (Test-Path -LiteralPath $script:HooksDir)) { return @() }
    $out = @()
    foreach ($d in (Get-ChildItem -Path $script:HooksDir -Directory -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath (Join-Path $d.FullName 'start.ps1')) { $out += $d.Name }
    }
    return ($out | Sort-Object)
}

function Get-ProfileName {
    # session-name prefix for an ad-hoc command: first word, sanitized
    param([string]$Command)
    $tok = $Command -split '\s+' | Select-Object -First 1
    if ($tok -match '[\\/]|^:') { $tok = [System.IO.Path]::GetFileNameWithoutExtension($tok) }
    elseif ($tok -match '\.(exe|bat|cmd|ps1|py|js)$') { $tok = [System.IO.Path]::GetFileNameWithoutExtension($tok) }
    $t = $tok -replace '[^a-zA-Z0-9]+', '-' -replace '^-+|-+$', ''
    if (-not $t) { $t = 'ka' }
    return $t.ToLower().Substring(0, [Math]::Min(16, $t.Length))
}

function Build-Command {
    # pane command string. tmux-windows quirk: argv[0] must be a bare *.exe name.
    param([string]$Profile, [string[]]$Args2)
    $hook = Join-Path $script:HooksDir (Join-Path $Profile 'start.ps1')
    if (Test-Path -LiteralPath $hook) {
        $cmd = "$script:PsExe -NoProfile -ExecutionPolicy Bypass -File $hook"
        if ($Args2) { $cmd = $cmd + ' ' + ($Args2 -join ' ') }
        return $cmd
    }
    return "cmd.exe /c " + ($Args2 -join ' ')
}

function Invoke-Tmux {
    # native stderr must not surface as error records (EAP=Stop elsewhere would throw)
    param([string[]]$TmuxArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try { $out = & $script:tmux @TmuxArgs 2>$null } finally { $ErrorActionPreference = $prev }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Get-Sessions {
    param([string]$Profile)
    $r = Invoke-Tmux @('list-sessions', '-F', '#{session_name} #{session_created}')
    $out = $r.Out
    if ($r.Code -ne 0 -or -not $out) { return @() }
    $list = @()
    foreach ($line in $out) {
        if ($line -notmatch "^$([regex]::Escape($Profile))-\S+ \d+") { continue }
        $parts = $line -split ' ', 2
        $list += [pscustomobject]@{
            Name    = $parts[0]
            Created = [int64]$parts[1]
            Started = [DateTimeOffset]::FromUnixTimeSeconds([int64]$parts[1]).LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss')
        }
    }
    # comma wrap: keep a single-element array an array across the return boundary
    return ,@($list)
}

function Get-Labels {
    # optional label hook: args are name/epoch pairs, output one line per input, in order
    param([string]$Profile, $Sessions)
    $hook = Join-Path $script:HooksDir (Join-Path $Profile 'label.ps1')
    if (-not (Test-Path -LiteralPath $hook) -or -not $Sessions) { return @() }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $hook)
    foreach ($s in $Sessions) { $a += $s.Name; $a += [string]$s.Created }
    $out = & $script:PsExe @a 2>$null
    if (-not $out) { return @() }
    $out = @($out)
    while ($out.Count -lt $Sessions.Count) { $out += '' }
    return $out
}

function Enter-ProfileLock {
    # serialize session creation per profile (name races, double launches)
    param([string]$Profile)
    $name = "Local\keepalive-$Profile"
    $exists = $false
    $m = [System.Threading.Mutex]::TryOpenExisting($name, [ref]$exists)
    if (-not $exists) { $m = New-Object System.Threading.Mutex($false, $name) }
    [void]$m.WaitOne(30000)
    return $m
}

function New-Session {
    param([string]$Profile, [string[]]$Args2)
    $lock = Enter-ProfileLock -Profile $Profile
    try {
        $name = "$Profile-" + (Get-Date).ToString('HHmmss')
        $i = 1
        while ($true) {
            $r = Invoke-Tmux @('has-session', '-t', $name)
            if ($r.Code -ne 0) { break }
            $name = "$Profile-" + (Get-Date).ToString('HHmmss') + "$i"; $i++
        }
        $cmd = Build-Command -Profile $Profile -Args2 $Args2
        $r = Invoke-Tmux @('new-session', '-d', '-s', $name, $cmd)
        if ($r.Code -ne 0) { throw "tmux new-session failed: $($r.Out)" }
        return $name
    } finally {
        $lock.ReleaseMutex()
        $lock.Dispose()
    }
}

function Stop-Session {
    # optional stop hook first (graceful process kill), then kill the tmux session
    param([string]$Profile, [string]$Name)
    $hook = Join-Path $script:HooksDir (Join-Path $Profile 'stop.ps1')
    if (Test-Path -LiteralPath $hook) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try { & $script:PsExe -NoProfile -ExecutionPolicy Bypass -File $hook 2>$null } finally { $ErrorActionPreference = $prev }
    }
    [void](Invoke-Tmux @('kill-session', '-t', $Name))
}

function Invoke-Attach {
    param([string]$Name)
    & $script:tmux attach-session -t $Name
    exit $LASTEXITCODE
}

function Show-Menu {
    # always shown (even with zero sessions). Enter = new, 1-N = attach, sN = stop, q = quit
    param([string]$Profile, [string[]]$NewArgs)
    while ($true) {
        $sessions = Get-Sessions -Profile $Profile
        $labels = Get-Labels -Profile $Profile -Sessions $sessions
        $count = if ($sessions) { $sessions.Count } else { 0 }
        Write-Host "keepalive '$Profile' - $count running"
        $n = 1
        foreach ($s in $sessions) {
            $label = ''
            if ($labels[$n - 1]) { $label = '  ' + $labels[$n - 1] }
            Write-Host ("  {0}) {1}  started {2}{3}" -f $n, $s.Name, $s.Started, $label)
            $n++
        }
        Write-Host "  [1-$count] attach   s1 stop #1   Enter new   q quit"
        $choice = Read-Host ' >'
        if ($choice -match '^[qQ]') { exit 0 }
        if ($choice -match '^\s*$') {
            $name = New-Session -Profile $Profile -Args2 $NewArgs
            Invoke-Attach -Name $name
        }
        if ($choice -match '^\s*s\s?(\d+)\s*$') {
            $idx = [int]$Matches[1]
            if ($idx -ge 1 -and $idx -le $count) {
                $target = $sessions[$idx - 1].Name
                Stop-Session -Profile $Profile -Name $target
                Write-Host "stopped $target"
                continue
            }
            Write-Host "no session #$idx"
        }
        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $count) {
            Invoke-Attach -Name $sessions[[int]$choice - 1].Name
        }
        Write-Host "invalid choice: $choice"
    }
}

function Start-NoTmux {
    # fallback without tmux: run the payload in the foreground (dies on disconnect)
    param([string]$Profile, [string[]]$Args2)
    Write-Host 'tmux not found (winget install arndawg.tmux-windows). Running in the foreground; the process dies when the connection drops.'
    $cmd = Build-Command -Profile $Profile -Args2 $Args2
    & $cmd
    exit $LASTEXITCODE
}

# ---------------------------------------------------------------- main (test seam)
if ($env:KA_NO_MAIN) { return }

$script:tmux = Find-Tmux

$mode = $null
$name = $null
$args2 = @()
foreach ($a in $All) {
    switch ($a) {
        '-l' { $mode = 'list' }
        '--list' { $mode = 'list' }
        '-n' { $mode = 'new' }
        '--new' { $mode = 'new' }
        '-k' { $mode = 'kill' }
        '--kill' { $mode = 'kill' }
        default {
            if (-not $name) { $name = $a } else { $args2 += $a }
        }
    }
}

if (-not $name) {
    $profiles = Get-HookProfiles
    if (-not $profiles) { Write-Host 'no hook profiles found and no command given. usage: ka <profile-or-command> [args...]'; exit 1 }
    if ($profiles.Count -eq 1) { $name = $profiles[0] }
    else {
        Write-Host 'keepalive profiles:'
        $n = 1
        foreach ($p in $profiles) { Write-Host "  $n) $p"; $n++ }
        while ($true) {
            $c = Read-Host 'pick a profile [1-$($profiles.Count)]'
            if ($c -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $profiles.Count) { $name = $profiles[[int]$c - 1]; break }
            Write-Host "invalid choice: $c"
        }
    }
}

$isHook = Test-Path -LiteralPath (Join-Path $script:HooksDir (Join-Path $name 'start.ps1'))
if (-not $isHook) {
    # ad-hoc command: profile = sanitized first word, full command kept in args
    $raw = @($name)
    if ($args2.Count -gt 0) { $raw += $args2 }
    $name = Get-ProfileName -Command $raw[0]
    $args2 = $raw
}

if (-not $script:tmux) { Start-NoTmux -Profile $name -Args2 $args2 }

$sessions = Get-Sessions -Profile $name

if ($mode -eq 'list') {
    if (-not $sessions) { Write-Host "no '$name' sessions running"; exit 0 }
    $labels = Get-Labels -Profile $name -Sessions $sessions
    $n = 1
    foreach ($s in $sessions) {
        $label = if ($labels[$n - 1]) { '  ' + $labels[$n - 1] } else { '' }
        Write-Host ("  {0}) {1}  started {2}{3}" -f $n, $s.Name, $s.Started, $label)
        $n++
    }
    exit 0
}

if ($mode -eq 'kill') {
    if (-not $sessions) { Write-Host "no '$name' sessions running"; exit 0 }
    foreach ($s in $sessions) { Stop-Session -Profile $name -Name $s.Name; Write-Host "stopped $($s.Name)" }
    exit 0
}

if ($mode -eq 'new') {
    $sname = New-Session -Profile $name -Args2 $args2
    Invoke-Attach -Name $sname
}

Show-Menu -Profile $name -NewArgs $args2
