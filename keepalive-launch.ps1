# keepalive core: run/attach any command in a tmux session that survives SSH disconnects.
#
# Usage:
#   keepalive                     dashboard of all running sessions (attach, stop, start)
#   keepalive <profile-or-command> [args...]
#                       start a new session and attach (observe it)
#   keepalive <x> -l    list sessions of x
#   keepalive <x> --detach
#                       start a new session, print its name, exit (headless, no attach)
#                       (no short flag: -d is eaten by powershell's built-in -Debug)
#   keepalive <x> -k    stop all sessions of x
#   keepalive --flat    machine-readable list of all sessions (for agents)
#   keepalive --flat --launch <x> [args...]   start, print the name, exit
#   keepalive --flat --stop <name>            stop one session by exact name
#   keepalive --flat --log <name>             print recent pane output
#   keepalive --help    human and agent usage
#
# A "profile" is either a hooks/<name>/ folder (start.ps1 required, label.ps1 and
# stop.ps1 optional) or any ad-hoc command line wrapped in cmd.exe /c.
#
# Test seam: set KEEPALIVE_NO_MAIN=1 to dot-source for its functions only.

param([Parameter(ValueFromRemainingArguments = $true)] $All)

# keep EAP at Continue: native stderr under EAP=Stop becomes a terminating error
$script:HooksDir = $env:KEEPALIVE_HOOKS_DIR
if (-not $script:HooksDir) { $script:HooksDir = Join-Path $PSScriptRoot 'hooks' }
$script:PsExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
if (-not $script:PsExe) { $script:PsExe = 'powershell.exe' }
$tuiFile = Join-Path $PSScriptRoot 'tui.ps1'
if (Test-Path -LiteralPath $tuiFile) { . $tuiFile }

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
    if (-not $t) { $t = 'keepalive' }
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
        # -\d+ (not -\S+): session suffix is a timestamp, so 'qwen' does not match 'qwen-mm-*'
        if ($line -notmatch "^$([regex]::Escape($Profile))-\d+ \d+") { continue }
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

function Get-AllSessions {
    # every keepalive session (all profiles), sorted profile/created/name (name breaks
    # same-second ties; Sort-Object is not stable); non-keepalive tmux sessions skipped
    $r = Invoke-Tmux @('list-sessions', '-F', '#{session_name} #{session_created}')
    $out = $r.Out
    if ($r.Code -ne 0 -or -not $out) { return @() }
    $list = @()
    foreach ($line in $out) {
        if ($line -notmatch '^(\S+)-\d{6,}(-\d+)? (\d+)$') { continue }
        $nm = ($line -split ' ', 2)[0]
        $created = [int64]$Matches[3]
        $list += [pscustomobject]@{
            Profile = $Matches[1]
            Name    = $nm
            Created = $created
            Started = [DateTimeOffset]::FromUnixTimeSeconds($created).LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss')
        }
    }
    $list = @($list | Sort-Object @{Expression='Profile'}, @{Expression='Created'}, @{Expression='Name'})
    # comma wrap: keep a single-element array an array across the return boundary
    return ,@($list)
}

function Get-AllLabels {
    # per-profile label hooks, keyed by session name
    param($All)
    $labels = @{}
    if (-not $All) { return $labels }
    $byProf = @{}
    foreach ($s in $All) {
        if (-not $byProf.ContainsKey($s.Profile)) { $byProf[$s.Profile] = @() }
        $byProf[$s.Profile] += $s
    }
    foreach ($prof in $byProf.Keys) {
        $hook = Join-Path $script:HooksDir (Join-Path $prof 'label.ps1')
        if (-not (Test-Path -LiteralPath $hook)) { continue }
        $sess = $byProf[$prof]
        $out = Get-Labels -Profile $prof -Sessions $sess
        for ($i = 0; $i -lt $sess.Count; $i++) {
            if ($out[$i]) { $labels[$sess[$i].Name] = $out[$i] }
        }
    }
    return $labels
}

function Flat-List {
    # machine-readable: one line per session, name|profile|started|label
    $all = Get-AllSessions
    $labels = Get-AllLabels -All $all
    foreach ($s in $all) {
        $label = ''
        if ($labels.ContainsKey($s.Name)) { $label = $labels[$s.Name] }
        Write-Output ($s.Name + '|' + $s.Profile + '|' + $s.Started + '|' + $label)
    }
}

function Stop-ByName {
    # stop one session by exact name (stop hook runs under its profile)
    param([string]$Name)
    $target = $null
    foreach ($s in (Get-AllSessions)) { if ($s.Name -eq $Name) { $target = $s; break } }
    if (-not $target) { Write-Host "no session $Name"; return 1 }
    if (-not (Stop-Session -Profile $target.Profile -Name $target.Name)) { return 1 }
    Write-Host "stopped $Name"
    return 0
}

function Resolve-AdHoc {
    # not a hook profile: the whole line is the command, profile = sanitized first word
    param([string]$Name, [string[]]$Args2)
    $isHook = Test-Path -LiteralPath (Join-Path $script:HooksDir (Join-Path $Name 'start.ps1'))
    if ($isHook) { return , @($Name, $Args2) }
    $raw = @($Name)
    if ($Args2.Count -gt 0) { $raw += $Args2 }
    # comma binds tighter than arg passing: build the pair explicitly or $raw is eaten by -Command
    $prof = Get-ProfileName -Command $raw[0]
    return , @($prof, $raw)
}

function Test-CommandExists {
    # ad-hoc first token must be runnable by cmd.exe, else the pane dies at once
    param([string]$Token)
    if ($Token -match '[\\/]|^:') { return (Test-Path -LiteralPath $Token) }
    return [bool](Get-Command $Token -CommandType Application -ErrorAction SilentlyContinue)
}

function Resolve-Start {
    # Resolve-AdHoc plus a guard: refuse ad-hoc commands that would exit immediately
    param([string]$Name, [string[]]$Args2)
    $rp = Resolve-AdHoc -Name $Name -Args2 $Args2
    $hook = Join-Path $script:HooksDir (Join-Path $rp[0] 'start.ps1')
    $tok = (@($rp[1][0]) -split '\s+')[0]
    if (-not (Test-Path -LiteralPath $hook) -and -not (Test-CommandExists -Token $tok)) {
        $profs = (Get-HookProfiles) -join ', '
        throw "'$tok' is not a hook profile (profiles: $profs) and not found on PATH - the session would exit immediately"
    }
    return $rp
}

function Get-Labels {
    # optional label hook: args are name/epoch pairs, output one line per input, in order
    param([string]$Profile, $Sessions)
    $hook = Join-Path $script:HooksDir (Join-Path $Profile 'label.ps1')
    if (-not (Test-Path -LiteralPath $hook) -or -not $Sessions) { return , @() }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $hook)
    foreach ($s in $Sessions) { $a += $s.Name; $a += [string]$s.Created }
    $out = & $script:PsExe @a 2>$null
    if (-not $out) { return , @() }
    $out = @($out)
    while ($out.Count -lt $Sessions.Count) { $out += '' }
    # , $out: keep 1-element arrays from unrolling to a bare string
    return , $out
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

function Get-LockState {
    # session lock is a tmux user option: @keepalive_locked 1
    param([string]$Name)
    $r = Invoke-Tmux @('show-options', '-t', $Name, '@keepalive_locked')
    if ($r.Code -ne 0) { return $false }
    if (($r.Out -join ' ') -match '@keepalive_locked\s+(\d+)') { return ($Matches[1] -eq '1') }
    return $false
}

function Set-Lock {
    param([string]$Name, [bool]$On)
    if ($On) { [void](Invoke-Tmux @('set-option', '-t', $Name, '@keepalive_locked', '1')) }
    else {
        $r = Invoke-Tmux @('unset-option', '-t', $Name, '@keepalive_locked')
        if ($r.Code -ne 0) { [void](Invoke-Tmux @('set-option', '-t', $Name, '@keepalive_locked', '0')) }
    }
}

function Stop-Session {
    # optional stop hook first (graceful process kill), then kill the tmux session.
    # locked sessions are refused (return $false) until --unlock-process
    param([string]$Profile, [string]$Name)
    if (Get-LockState -Name $Name) {
        Write-Host "locked $Name (unlock with: keepalive --unlock-process $Name)"
        return $false
    }
    $hook = Join-Path $script:HooksDir (Join-Path $Profile 'stop.ps1')
    if (Test-Path -LiteralPath $hook) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try { & $script:PsExe -NoProfile -ExecutionPolicy Bypass -File $hook 2>$null } finally { $ErrorActionPreference = $prev }
    }
    [void](Invoke-Tmux @('kill-session', '-t', $Name))
    return $true
}

function Invoke-Attach {
    param([string]$Name)
    # redirected stdin cannot attach (tmux fails on non-tty): print the name and exit
    if ([Console]::IsInputRedirected) { Write-Output $Name; exit 0 }
    & $script:tmux attach-session -t $Name
    exit $LASTEXITCODE
}

function Show-Dashboard {
    # global view of all running sessions. 1-N = attach, sN = stop, Enter = start named, q = quit
    # colored TUI on real terminals, plain menu when output is piped
    $onTty = -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
    if (($onTty -or $env:KEEPALIVE_FORCE_TUI -eq '1') -and (Get-Command Show-TuiDashboard -ErrorAction SilentlyContinue)) {
        Show-TuiDashboard
        return
    }
    while ($true) {
        $all = Get-AllSessions
        $labels = Get-AllLabels -All $all
        $count = $all.Count
        Write-Host "keepalive - $count running"
        $n = 1
        foreach ($s in $all) {
            $label = ''
            if ($labels.ContainsKey($s.Name)) { $label = '  ' + $labels[$s.Name] }
            Write-Host ("  {0}) {1}  started {2}{3}" -f $n, $s.Name, $s.Started, $label)
            $n++
        }
        Write-Host "  [1-$count] attach   s1 stop #1   Enter start name   q quit"
        $choice = Read-Host ' >'
        if ($choice -match '^\s*[qQ]\s*$') { exit 0 }
        if ($choice -match '^\s*$') {
            $raw = Read-Host 'start'
            if ($raw -match '^\s*$') { continue }
            try {
                $rp = Resolve-Start -Name $raw -Args2 @()
                $sname = New-Session -Profile $rp[0] -Args2 $rp[1]
                Invoke-Attach -Name $sname
            } catch { Write-Host $_.Exception.Message }
        }
        if ($choice -match '^\s*s\s?(\d+)\s*$') {
            $idx = [int]$Matches[1]
            if ($idx -ge 1 -and $idx -le $count) {
                $target = $all[$idx - 1]
                if (Stop-Session -Profile $target.Profile -Name $target.Name) { Write-Host "stopped $($target.Name)" }
                continue
            }
            Write-Host "no session #$idx"
        }
        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $count) {
            Invoke-Attach -Name $all[[int]$choice - 1].Name
        }
        Write-Host "invalid choice: $choice"
    }
}

function Show-Help {
    # human and agent usage; printed to stdout
    $lines = @()
    $lines += 'keepalive - keep processes running in tmux, survives SSH disconnects'
    $lines += ''
    $lines += 'HUMAN (interactive; colored TUI on a real terminal):'
    $lines += '  keepalive                  dashboard of all running sessions'
    $lines += '                             1-N attach   sN stop   Enter start named   q quit'
    $lines += '  keepalive <x> [args...]    start a new session of x and attach'
    $lines += '  keepalive <x> -l           list sessions of x'
    $lines += '  keepalive <x> --detach     start a new session, print its name, exit'
    $lines += '  keepalive <x> -k           stop all sessions of x'
    $lines += ''
    $lines += 'AI AGENT (no prompts, results on stdout):'
    $lines += '  keepalive --flat           list all sessions, one per line:'
    $lines += '                             name|profile|started|label'
    $lines += '  keepalive --flat --launch <x> [args...]'
    $lines += '                             start a new session of x, print its name, exit'
    $lines += '  keepalive --flat --stop <name>          stop one session by exact name'
    $lines += '  keepalive --flat --kill <profile>       stop all sessions of a profile'
    $lines += '  keepalive --flat --log <name>           print recent pane output of a session'
    $lines += '  keepalive --flat --launch <x> --lock    start a new session and lock it'
    $lines += '  keepalive --lock-process <name>         refuse --stop/-k for a session'
    $lines += '  keepalive --unlock-process <name>       clear the lock'
    $lines += ''
    $lines += 'AGENTS: lock your own session before any stop/kill work (launch with'
    $lines += '--lock, or --lock-process on your session name). Locked sessions are'
    $lines += 'refused with a warning, so a locked agent cannot kill itself. An'
    $lines += 'unlocked agent can; that makes it unreliable. Locking is the safe default.'
    $lines += ''
    $lines += 'Hooks: hooks/<name>/start.ps1 (plus optional label.ps1 and stop.ps1)'
    $lines += 'add named profiles. Any other command runs as cmd.exe /c in the session.'
    foreach ($l in $lines) { Write-Output $l }
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
if ($env:KEEPALIVE_NO_MAIN) { return }

$script:tmux = Find-Tmux

$mode = $null
$flat = $false
$lockNew = $false
$name = $null
$stopName = $null
$logName = $null
$lockName = $null
$args2 = @()
$i = 0
while ($i -lt $All.Count) {
    $a = $All[$i]
    switch ($a) {
        '-h' { $mode = 'help' }
        '--help' { $mode = 'help' }
        'help' { $mode = 'help' }
        '--flat' { $flat = $true }
        '-l' { $mode = 'list' }
        '--list' { $mode = 'list' }
        '-n' { $mode = 'new' }
        '--new' { $mode = 'new' }
        '--launch' { $mode = 'launch'; $i++; if ($i -lt $All.Count) { $name = $All[$i] } }
        '--detach' { $mode = 'detach' }
        '-k' { $mode = 'kill' }
        '--kill' { $mode = 'kill' }
        '--stop' { $mode = 'stop'; $i++; if ($i -lt $All.Count) { $stopName = $All[$i] } }
        '--log' { $mode = 'log'; $i++; if ($i -lt $All.Count) { $logName = $All[$i] } }
        '--lock-process' { $mode = 'lock'; $i++; if ($i -lt $All.Count) { $lockName = $All[$i] } }
        '--unlock-process' { $mode = 'unlock'; $i++; if ($i -lt $All.Count) { $lockName = $All[$i] } }
        '--lock' { $lockNew = $true }
        default {
            if (-not $name) { $name = $a } else { $args2 += $a }
        }
    }
    $i++
}

if ($mode -eq 'help') { Show-Help; exit 0 }

if ($mode -eq 'stop') {
    if (-not $stopName) { Write-Output 'usage: keepalive --stop <name>'; exit 1 }
    if (-not $script:tmux) { Write-Output 'tmux not found (winget install arndawg.tmux-windows)'; exit 1 }
    exit (Stop-ByName -Name $stopName)
}

if ($mode -eq 'log') {
    if (-not $logName) { Write-Output 'usage: keepalive --log <name>'; exit 1 }
    if (-not $script:tmux) { Write-Output 'tmux not found (winget install arndawg.tmux-windows)'; exit 1 }
    $r = Invoke-Tmux @('capture-pane', '-pt', $logName, '-p', '-S', '-200')
    if ($r.Code -ne 0) { Write-Output "no session $logName"; exit 1 }
    $out = @($r.Out | ForEach-Object { $_.TrimEnd() })
    while ($out.Count -gt 1 -and $out[$out.Count - 1] -eq '') { $out = $out[0..($out.Count - 2)] }
    Write-Output $out
    exit 0
}

if ($mode -eq 'lock' -or $mode -eq 'unlock') {
    if (-not $lockName) { Write-Output "usage: keepalive --$($mode)-process <name>"; exit 1 }
    if (-not $script:tmux) { Write-Output 'tmux not found (winget install arndawg.tmux-windows)'; exit 1 }
    $r = Invoke-Tmux @('has-session', '-t', $lockName)
    if ($r.Code -ne 0) { Write-Host "no session $lockName"; exit 1 }
    Set-Lock -Name $lockName -On ($mode -eq 'lock')
    Write-Host "$($mode) $lockName"
    exit 0
}

if ($mode -eq 'launch' -and -not $name) { Write-Output 'usage: keepalive --launch <x> [args...]'; exit 1 }

if (-not $name) {
    if ($flat) { Flat-List; exit 0 }
    if ($mode) { Write-Host 'usage: keepalive <profile-or-command> [args...]   (no name: dashboard of all sessions)'; exit 1 }
    Show-Dashboard
    exit 0
}

try { $rp = Resolve-Start -Name $name -Args2 $args2 } catch { Write-Host $_.Exception.Message; exit 1 }
$name = $rp[0]
$args2 = $rp[1]

if (-not $script:tmux) { Start-NoTmux -Profile $name -Args2 $args2 }

# print the session name and exit: --detach, --launch, --flat
if ($mode -eq 'detach' -or $mode -eq 'launch' -or $flat) {
    $sname = New-Session -Profile $name -Args2 $args2
    if ($lockNew) { Set-Lock -Name $sname -On $true }
    Write-Output $sname
    exit 0
}

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
    foreach ($s in $sessions) {
        if (Stop-Session -Profile $name -Name $s.Name) { Write-Host "stopped $($s.Name)" }
    }
    exit 0
}

# default (also -n): start a new session and attach
$sname = New-Session -Profile $name -Args2 $args2
if ($lockNew) { Set-Lock -Name $sname -On $true }
Invoke-Attach -Name $sname
