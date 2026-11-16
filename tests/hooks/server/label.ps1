# test hook: port status per session (args: name epoch name epoch ...)
param([Parameter(ValueFromRemainingArguments = $true)] $Pairs)
$port = 18099
$up = $false
try {
    $c = New-Object Net.Sockets.TcpClient
    $ar = $c.BeginConnect('127.0.0.1', $port, $null, $null)
    if ($ar.AsyncWaitHandle.WaitOne(300)) { $c.EndConnect($ar); $up = $true }
    $c.Close()
} catch {}
$label = if ($up) { "server :$port up" } else { "server :$port down" }
$n = [Math]::Floor($Pairs.Count / 2)
for ($i = 0; $i -lt $n; $i++) { Write-Output $label }
