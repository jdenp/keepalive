# test hook: kill whatever listens on the test port, wait for it to free
$port = 18099
$pids = @()
foreach ($l in (netstat -ano 2>$null)) {
    # trim: captured netstat lines carry a trailing \r that breaks the $ anchor
    if ($l.Trim() -match "\b:$port\s+\S+\s+LISTENING\s+(\d+)$") { $pids += $Matches[1] }
}
foreach ($p in @($pids | Select-Object -Unique)) {
    try { Stop-Process -Id $p -Force -ErrorAction Stop } catch {}
}
$deadline = (Get-Date).AddSeconds(10)
while ($pids -and (Get-Date) -lt $deadline) {
    $still = $false
    foreach ($l in (netstat -ano 2>$null)) { if ($l -match "\b:$port\s+\S+\s+LISTENING") { $still = $true; break } }
    if (-not $still) { break }
    Start-Sleep -Milliseconds 250
}
