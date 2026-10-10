# qwens label hook: server port status per session (args: name epoch name epoch ...)
param([Parameter(ValueFromRemainingArguments = $true)] $Pairs)
$bat = $env:QWENS_SERVER
if (-not $bat) { $bat = 'C:\Users\short\Desktop\llama\Swift-3.8-27B_start_server.bat' }
$port = 8083
if (Test-Path -LiteralPath $bat) {
    $m = Select-String -Path $bat -Pattern '--port\s+(\d+)' -ErrorAction SilentlyContinue
    if ($m) { $port = [int]($m.Matches[0].Groups[1].Value) }
}
$up = $false
try {
    $c = New-Object Net.Sockets.TcpClient
    $ar = $c.BeginConnect('127.0.0.1', $port, $null, $null)
    if ($ar.AsyncWaitHandle.WaitOne(300)) { $c.EndConnect($ar); $up = $true }
    $c.Close()
} catch {}
$label = if ($up) { "llama :$port up" } else { "llama :$port down" }
$n = [Math]::Floor($Pairs.Count / 2)
for ($i = 0; $i -lt $n; $i++) { Write-Output $label }
