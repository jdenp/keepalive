# test hook: run the dummy server in the pane, teeing output to a log; if the port is already open, stream that log instead
$bat = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'dummy_server.bat'
$port = 18099
$dir = Join-Path $env:TEMP 'keepalive-test'
$log = Join-Path $dir 'server.log'

function Test-PortOpen {
    param([int]$P)
    foreach ($l in (netstat -ano 2>$null)) {
        $f = @($l.Trim() -split '\s+')
        if ($f.Count -ge 5 -and $f[3] -eq 'LISTENING' -and ($f[1] -eq "127.0.0.1:$P" -or $f[1] -eq "0.0.0.0:$P")) { return $true }
    }
    return $false
}

if (Test-PortOpen -P $port) {
    Write-Host "server already running on :$port - streaming log (Ctrl-C to stop)"
    if (-not (Test-Path -LiteralPath $log)) {
        # started outside keepalive, no log to stream: idle so the pane survives
        while ($true) { Start-Sleep -Seconds 3600 }
    }
    Get-Content -LiteralPath $log -Tail 20
    $off = (Get-Item -LiteralPath $log).Length
    while ($true) {
        Start-Sleep -Milliseconds 500
        $size = (Get-Item -LiteralPath $log -ErrorAction SilentlyContinue).Length
        if ($null -eq $size) { continue }
        if ($size -lt $off) { $off = 0 }
        if ($size -gt $off) {
            $fs = [System.IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
            try {
                [void]$fs.Seek($off, 'Begin')
                $chunk = (New-Object System.IO.StreamReader($fs)).ReadToEnd()
                $off = $fs.Position
                if ($chunk) { Write-Host $chunk -NoNewline }
            } finally { $fs.Close() }
        }
    }
}

New-Item -ItemType Directory -Force -Path $dir | Out-Null
Write-Host "starting server on :$port"
cmd.exe /c $bat 2>&1 | ForEach-Object { $l = "$_"; Write-Host $l; Add-Content -LiteralPath $log -Value $l -Encoding utf8 }
exit $LASTEXITCODE
