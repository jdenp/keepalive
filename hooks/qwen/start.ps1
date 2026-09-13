# qwen hook: run the local llama server in the pane, streaming its output to the log.
# If the server port is already open, stream the existing log instead of starting a second server.
$bat = $env:QWEN_SERVER
if (-not $bat) { $bat = 'C:\Users\short\Desktop\llama\Unsloth-3.8-27B_start_server.bat' }
$dir = Join-Path $env:LOCALAPPDATA 'qwen'
$log = Join-Path $dir 'qwen.log'
$port = 8082
if (Test-Path -LiteralPath $bat) {
    $m = Select-String -Path $bat -Pattern '--port\s+(\d+)' -ErrorAction SilentlyContinue
    if ($m) { $port = [int]($m.Matches[0].Groups[1].Value) }
}

function Test-PortOpen {
    # LISTEN-state check: a TCP probe would sit in a tiny listen backlog and
    # poison later probes, so ask the kernel instead
    param([int]$P)
    try {
        $conns = Get-NetTCPConnection -State Listen -LocalPort $P -ErrorAction Stop
        if (@($conns).Count -gt 0) { return $true }
    } catch {}
    foreach ($l in (netstat -ano 2>$null)) {
        if ($l -match "\b:$P\s+\S+\s+LISTENING\b") { return $true }
    }
    return $false
}

function Get-LogTail {
    # follow the log from $off, printing appended chunks
    param([string]$Path, [long]$Start)
    $off = $Start
    while ($true) {
        Start-Sleep -Milliseconds 500
        $size = (Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue).Length
        if ($null -eq $size) { continue }
        if ($size -lt $off) { $off = 0 }
        if ($size -gt $off) {
            $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
            try {
                [void]$fs.Seek($off, 'Begin')
                $sr = New-Object System.IO.StreamReader($fs)
                $chunk = $sr.ReadToEnd()
                $off = $fs.Position
                if ($chunk) { Write-Host $chunk -NoNewline }
            } finally { $fs.Close() }
        }
    }
}

if (Test-PortOpen -P $port) {
    Write-Host "qwen already running on :$port - streaming log (Ctrl-C to stop)"
    if (Test-Path -LiteralPath $log) {
        Get-Content -LiteralPath $log -Tail 20
        Get-LogTail -Path $log -Start (Get-Item -LiteralPath $log).Length
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $bat)) {
    Write-Host "qwen server not found: $bat (set QWEN_SERVER to override)"
    Start-Sleep -Seconds 10
    exit 1
}

New-Item -ItemType Directory -Force -Path $dir | Out-Null
Write-Host "starting qwen server on :$port"
Write-Host "command: $bat"
Write-Host "log: $log"
Write-Host ''
cmd.exe /c $bat 2>&1 | ForEach-Object { $l = "$_"; Write-Host $l; Add-Content -LiteralPath $log -Value $l -Encoding utf8 }
exit $LASTEXITCODE
