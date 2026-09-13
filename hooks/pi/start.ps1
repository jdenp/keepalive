# pi hook: run the pi coding agent in the pane (tmux keeps it alive across SSH drops).
# -c/--continue picks the most recent session file not already held by another live pi session.
param([Parameter(ValueFromRemainingArguments = $true)] $Rest)

# pi writes to native stderr; EAP=Stop would turn that into a terminating error
$ErrorActionPreference = 'Continue'

$repo = 'C:\Repos'
$node = 'C:\Program Files\nodejs\node.exe'
$cli = Join-Path $env:APPDATA 'npm\node_modules\@earendil-works\pi-coding-agent\dist\bundle\cli.js'

Set-Location $repo

function Get-TmuxPath {
    $c = Get-Command tmux.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $link = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\tmux.exe'
    if (Test-Path -LiteralPath $link) { return $link }
    return $null
}

function Get-PiSessionsDir {
    if ($env:PI_SESSIONS_DIR) { return $env:PI_SESSIONS_DIR }
    return (Join-Path $env:USERPROFILE '.pi\agent\sessions')
}

function Get-PiSessionFiles {
    # recent session files as [pscustomobject]@{Ts,Id,Path}
    param([string]$Dir)
    $out = @()
    if (-not (Test-Path -LiteralPath $Dir)) { return $out }
    $cutoff = (Get-Date).AddDays(-14)
    foreach ($f in (Get-ChildItem -Path $Dir -Filter '*.jsonl' -Recurse -File -ErrorAction SilentlyContinue)) {
        if ($f.Name -notmatch '^(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})-(\d{3})Z_([0-9a-f-]{36})') { continue }
        $dt = [DateTime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4], [int]$Matches[5], [int]$Matches[6], [int]$Matches[7], [DateTimeKind]::Utc)
        $ts = [DateTimeOffset]::new($dt)
        if ($ts.LocalDateTime -lt $cutoff) { continue }
        # resumed sessions reuse old files, so match on the newer of
        # filename timestamp and last-write time
        $mtime = [DateTimeOffset]::new($f.LastWriteTime)
        $live = $ts
        if ($mtime.ToUnixTimeSeconds() -gt $ts.ToUnixTimeSeconds()) { $live = $mtime }
        $out += [pscustomobject]@{ Ts = $ts; Live = $live; Id = $Matches[8]; Path = $f.FullName }
    }
    return $out
}

function Get-UsedPiSessionIds {
    # ids of session files held by other live pi-* tmux sessions.
    # exact: the pane's node child was launched with --session <uuid>;
    # fallback: filename ts within 1h of session creation (fresh sessions)
    param([string]$Tmux)
    $used = @{}
    if (-not $Tmux) { return $used }
    $files = Get-PiSessionFiles -Dir (Get-PiSessionsDir)
    $mine = ''
    try { $mine = (& $Tmux display-message -p '#{session_name}' 2>$null) | Select-Object -First 1 } catch {}
    # note: tmux-windows list-panes -s only shows the current session, so
    # query each pi-* session individually
    $sessions = & $Tmux list-sessions -F "#{session_name} #{session_created}" 2>$null
    if (-not $sessions) { return $used }
    $live = @()
    foreach ($line in $sessions) {
        if ($line -notmatch '^(pi-\S+) (\d+)$') { continue }
        $nm = $Matches[1]
        $ep = [int64]$Matches[2]
        if ($nm -eq $mine) { continue }
        $pids = & $Tmux list-panes -t $nm -F "#{pane_pid}" 2>$null
        foreach ($pp in @($pids)) {
            if ($pp -match '^(\d+)$') { $live += [pscustomobject]@{ Name = $nm; Ep = $ep; Pid = [int]$Matches[1] } }
        }
    }
    $identified = @{}
    foreach ($s in $live) {
        $uuid = $null
        try {
            $kids = Get-CimInstance Win32_Process -Filter ("ParentProcessId = " + $s.Pid) -ErrorAction Stop
            foreach ($k in @($kids)) {
                if ($k.CommandLine -and $k.CommandLine -match '--session[= ]([0-9a-f-]{36})') { $uuid = $Matches[1]; break }
            }
        } catch {}
        if ($uuid) { $used[$uuid] = $true; $identified[$s.Name] = $true }
    }
    if ($files) {
        foreach ($s in $live) {
            if ($identified.ContainsKey($s.Name)) { continue }
            $c = [DateTimeOffset]::FromUnixTimeSeconds($s.Ep)
            $best = $null
            $bd = [int64]3600
            foreach ($p in $files) {
                $d = [Math]::Abs([int64]($p.Ts - $c).TotalSeconds)
                if ($d -le $bd) { $bd = $d; $best = $p }
            }
            if ($best) { $used[$best.Id] = $true }
        }
    }
    return $used
}

function Get-FreePiSessionId {
    # newest session file not held by another live pi session
    param([string]$Tmux)
    $files = Get-PiSessionFiles -Dir (Get-PiSessionsDir)
    if (-not $files) { return $null }
    $used = Get-UsedPiSessionIds -Tmux $Tmux
    $sorted = @($files | Sort-Object { $_.Ts } -Descending)
    foreach ($f in $sorted) { if (-not $used.ContainsKey($f.Id)) { return $f.Id } }
    return $null
}

# self-heal: server outlives ~/.tmux.conf, so re-assert what pi checks at startup
$tmux = Get-TmuxPath
if ($tmux) {
    & $tmux set-option -g extended-keys on 2>$null
    & $tmux set-option -g extended-keys-format csi-u 2>$null
}

$final = @()
$continue = $false
foreach ($a in $Rest) {
    if ($a -eq '-c' -or $a -eq '--continue') { $continue = $true } else { $final += $a }
}
if ($continue) {
    $id = Get-FreePiSessionId -Tmux $tmux
    if ($id) { $final += @('--session', $id) } else { $final += '-c' }
}

if ($env:KA_PI_DRY_RUN) {
    Write-Output ("DRYRUN: " + ($final -join ' '))
    exit 0
}

& $node $cli @final
exit $LASTEXITCODE
