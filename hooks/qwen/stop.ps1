# qwen stop hook: kill whatever is listening on the qwen port, wait for it to free.
$bat = $env:QWEN_SERVER
if (-not $bat) { $bat = 'C:\Users\short\Desktop\llama\Unsloth-3.8-27B_start_server.bat' }
$port = 8082
if (Test-Path -LiteralPath $bat) {
    $m = Select-String -Path $bat -Pattern '--port\s+(\d+)' -ErrorAction SilentlyContinue
    if ($m) { $port = [int]($m.Matches[0].Groups[1].Value) }
}
$pids = @()
foreach ($l in (netstat -ano 2>$null)) {
    if ($l -match "\b:$port\s+\S+\s+LISTENING\s+(\d+)$") { $pids += $Matches[1] }
}
$pids = @($pids | Select-Object -Unique)
foreach ($p in $pids) {
    try { Stop-Process -Id $p -Force -ErrorAction Stop } catch {}
}
if ($pids) {
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        $still = $false
        foreach ($l in (netstat -ano 2>$null)) {
            if ($l -match "\b:$port\s+\S+\s+LISTENING") { $still = $true; break }
        }
        if (-not $still) { break }
        Start-Sleep -Milliseconds 250
    }
}
