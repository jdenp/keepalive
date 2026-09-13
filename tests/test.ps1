# keepalive test suite: powershell -NoProfile -ExecutionPolicy Bypass -File tests/test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$env:KA_HOOKS_DIR = Join-Path $PSScriptRoot 'hooks'
$env:KA_NO_MAIN = '1'
. (Join-Path $root 'ka-launch.ps1')
Remove-Item Env:KA_NO_MAIN -ErrorAction SilentlyContinue

$script:tmux = Find-Tmux
$script:created = @()
$script:pass = 0
$script:fail = 0

function Assert {
    param([string]$Name, [bool]$Cond)
    if ($Cond) { $script:pass++; Write-Host "  ok   $Name" }
    else { $script:fail++; Write-Host "  FAIL $Name" }
}

function New-TestSession {
    param([string]$Name, [string]$Cmd)
    $err = & $script:tmux new-session -d -s $Name $Cmd 2>&1
    if ($LASTEXITCODE -ne 0) { throw "new-session $Name failed: $err" }
    $script:created += $Name
}

function Kill-TestSessions {
    foreach ($s in $script:created) { [void](Invoke-Tmux @('kill-session', '-t', $s)) }
    $script:created = @()
}

function Test-PortOpen {
    param([int]$P)
    foreach ($l in (netstat -ano 2>$null)) {
        if ($l -match "\b:$P\s+\S+\s+LISTENING\b") { return $true }
    }
    return $false
}

# kill whatever listens on $P (orphaned test servers survive kill-session)
function Kill-PortListener {
    param([int]$P)
    $lines = netstat -ano | Select-String (":$P\s+.*LISTENING")
    foreach ($l in $lines) {
        $procId = ($l.ToString().Trim() -split '\s+')[-1]
        if ($procId -match '^\d+$') { Stop-Process -Id ([int]$procId) -Force -ErrorAction SilentlyContinue }
    }
}

# sweep leftovers from crashed previous runs
foreach ($pat in @('echo-.*', 'ping-.*', 'pi-t.*', 'qtest-.*')) {
    foreach ($nm in @((& $script:tmux list-sessions -F "#{session_name}" 2>$null))) {
        if ($nm -match $pat) { [void](Invoke-Tmux @('kill-session', '-t', $nm)) }
    }
}
Kill-PortListener 18099
Start-Sleep -Milliseconds 300

Write-Host 'keepalive tests'

try {
    # --- discovery and helpers ---
    Assert 'find tmux' ($script:tmux -ne $null)
    Assert 'tmux path exists' (Test-Path -LiteralPath $script:tmux)
    $profiles = Get-HookProfiles
    Assert 'hook profiles include echo' ($profiles -contains 'echo')
    Assert 'profile name from path' ((Get-ProfileName -Command 'C:\tools\server.bat') -eq 'server')
    Assert 'profile name from command' ((Get-ProfileName -Command 'npm run dev') -eq 'npm')
    Assert 'profile name from exe' ((Get-ProfileName -Command 'ping.exe -n 5') -eq 'ping')
    $hookCmd = Build-Command -Profile 'echo' -Args2 @()
    Assert 'hook command uses start.ps1' ($hookCmd -match 'powershell.*hooks\\echo\\start\.ps1')
    $genCmd = Build-Command -Profile 'ping' -Args2 @('ping.exe', '-n', '5', '127.0.0.1')
    Assert 'generic command wraps cmd /c' ($genCmd -eq 'cmd.exe /c ping.exe -n 5 127.0.0.1')

    # --- session lifecycle ---
    $s1 = New-Session -Profile 'echo' -Args2 @()
    Assert 'new session name format' ($s1 -match '^echo-\d{6}$')
    $script:created += $s1
    $list = Get-Sessions -Profile 'echo'
    Assert 'list shows one echo session' ($list.Count -eq 1)
    Assert 'session has created epoch' ($list[0].Created -gt 0)
    $s2 = New-Session -Profile 'echo' -Args2 @()
    Assert 'second session gets unique name' ($s2 -ne $s1)
    $script:created += $s2
    Assert 'list shows two echo sessions' ((Get-Sessions -Profile 'echo').Count -eq 2)
    $labels = Get-Labels -Profile 'echo' -Sessions (Get-Sessions -Profile 'echo')
    Assert 'no label hook means no labels' (-not $labels)

    $sg = New-Session -Profile 'ping' -Args2 @('ping.exe', '-n', '30', '127.0.0.1')
    Assert 'generic session created' ($sg -match '^ping-\d{6}$')
    $script:created += $sg

    # --- pi label hook ---
    $fix = Join-Path $PSScriptRoot 'fixture-sessions'
    Remove-Item -Recurse -Force $fix -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $fix | Out-Null
    $now = [DateTimeOffset]::Now
    $midUuid = [guid]::NewGuid().ToString()
    function New-Fixture {
        param([string]$Dir, [TimeSpan]$Offset, [string]$Uuid, [string]$Prompt)
        $ts = $now.Add($Offset)
        $name = $ts.UtcDateTime.ToString('yyyy-MM-ddTHH-mm-ss-fffZ') + '_' + $Uuid + '.jsonl'
        $lines = @()
        $lines += '{"type":"session","id":"' + $Uuid + '","cwd":"C:\\Repos"}'
        if ($Prompt) {
            $lines += '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"' + $Prompt + '"}]}}'
        }
        $path = Join-Path $Dir $name
        Set-Content -LiteralPath $path -Value $lines -Encoding utf8
        # backdate mtime to the intended ts (fresh files would all match "now")
        $fi = Get-Item -LiteralPath $path
        $fi.LastWriteTime = $ts.LocalDateTime
        $fi.LastAccessTime = $ts.LocalDateTime
        return $name
    }
    $oldUuid = [guid]::NewGuid().ToString()
    $newUuid = [guid]::NewGuid().ToString()
    $null = New-Fixture -Dir $fix -Offset ([TimeSpan]::FromSeconds(-300)) -Uuid $oldUuid -Prompt $null
    $null = New-Fixture -Dir $fix -Offset ([TimeSpan]::FromSeconds(-100)) -Uuid $midUuid -Prompt 'the quick brown fox jumps over the lazy dog'
    $null = New-Fixture -Dir $fix -Offset ([TimeSpan]::FromSeconds(-5)) -Uuid $newUuid -Prompt $null

    $env:PI_SESSIONS_DIR = $fix
    $midEpoch = [string][int64]($now.AddSeconds(-100).ToUnixTimeSeconds())
    $labelOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'hooks\pi\label.ps1') 'pi-test-1' $midEpoch 2>$null
    Assert 'pi label truncated to 20 chars' (@($labelOut) -contains '"the quick brown fox..."')
    Remove-Item Env:PI_SESSIONS_DIR -ErrorAction SilentlyContinue

    # --- pi -c conflict: newest fixture is held, so mid must be picked ---
    $null = New-TestSession 'pi-t1' 'ping.exe -n 600 127.0.0.1'
    $null = New-TestSession 'pi-t2' 'ping.exe -n 600 127.0.0.1'
    Start-Sleep -Seconds 1
    $env:PI_SESSIONS_DIR = $fix
    $env:KA_PI_DRY_RUN = '1'
    $dry = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'hooks\pi\start.ps1') '-c' 2>$null
    Remove-Item Env:KA_PI_DRY_RUN -ErrorAction SilentlyContinue
    Remove-Item Env:PI_SESSIONS_DIR -ErrorAction SilentlyContinue
    Assert 'pi -c skips held session' (@($dry) -join ' ' -match ("--session " + $midUuid))

    # --- qwen hooks ---
    $env:QWEN_SERVER = Join-Path $PSScriptRoot 'dummy_server.bat'
    $qLabel = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'hooks\qwen\label.ps1') 'qwen-test-1' '1700000000' 2>$null
    Assert 'qwen label shows port' ((@($qLabel) -join ' ') -match 'llama :18099 (up|down)')

    Kill-PortListener 18099
    Start-Sleep -Milliseconds 500
    # start from a clean log so the tail stays short and the banner stays visible
    Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'qwen\qwen.log') -ErrorAction SilentlyContinue
    $null = New-TestSession 'qtest-1' "cmd.exe /c C:\Repos\keepalive\tests\qwen_test_start.bat"
    $up = $false
    for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Seconds 1; if (Test-PortOpen -P 18099) { $up = $true; break } }
    $pane = (& $script:tmux capture-pane -pt qtest-1 -p 2>$null) -join "`n"
    Assert 'qwen start opens port' $up
    Assert 'qwen start banner in pane' ($pane -match 'starting qwen server on :18099')
    $logPath = Join-Path $env:LOCALAPPDATA 'qwen\qwen.log'
    $logHas = $false
    if (Test-Path -LiteralPath $logPath) { $logHas = @((Select-String -Path $logPath -Pattern 'dummy llama-server on --port 18099' -ErrorAction SilentlyContinue)).Count -gt 0 }
    Assert 'qwen log written' $logHas

    $null = New-TestSession 'qtest-2' "cmd.exe /c C:\Repos\keepalive\tests\qwen_test_start.bat"
    Start-Sleep -Seconds 3
    $null = & $script:tmux has-session -t qtest-2 2>$null
    $q2ok = ($LASTEXITCODE -eq 0)
    $pane2 = ''
    if ($q2ok) { $pane2 = (& $script:tmux capture-pane -pt qtest-2 -p 2>$null) -join "`n" }
    Assert 'second qwen session alive' $q2ok
    Assert 'second qwen tails instead of double-start' ($pane2 -match 'already running on :18099')

    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'hooks\qwen\stop.ps1') 2>$null
    $freed = $false
    for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 500; if (-not (Test-PortOpen -P 18099)) { $freed = $true; break } }
    Assert 'qwen stop frees port' $freed
    Remove-Item Env:QWEN_SERVER -ErrorAction SilentlyContinue

    # --- TUI menu ---
    $env:KA_FORCE_TUI = '1'
    $tuiOut = @('q' | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'ka-launch.ps1') 'echo' 2>$null) -join "`n"
    Assert 'tui renders colored menu' (($tuiOut -match 'keepalive') -and ($tuiOut -match 'echo-') -and $tuiOut.Contains([char]27))
    $null = "s1`nq" | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'ka-launch.ps1') 'echo' 2>$null
    $stillThere = $false
    foreach ($nm in @(Get-Sessions -Profile 'echo')) { if ($nm.Name -eq $s1) { $stillThere = $true } }
    Assert 'tui stop stops the first session' (-not $stillThere)
    $env:KA_FORCE_TUI = ''
    $plainOut = @('q' | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'ka-launch.ps1') 'echo' 2>$null) -join "`n"
    Assert 'plain menu when piped' (($plainOut -match 'keepalive') -and (-not $plainOut.Contains([char]27)))

    # --- stop --- ($s1 was already stopped by the TUI test)
    $before = (Get-Sessions -Profile 'echo').Count
    Stop-Session -Profile 'echo' -Name $s2
    Start-Sleep -Milliseconds 500
    $after = (Get-Sessions -Profile 'echo').Count
    Assert 'stop session kills it' ($after -eq ($before - 1))

    Remove-Item -Recurse -Force $fix -ErrorAction SilentlyContinue
}
finally {
    Kill-TestSessions
    Kill-PortListener 18099
}

Write-Host ""
Write-Host ("passed {0}, failed {1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
