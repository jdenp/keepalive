# pi label hook: one 20-char prompt label per session (args: name epoch name epoch ...)
param([Parameter(ValueFromRemainingArguments = $true)] $Pairs)

$dir = $env:PI_SESSIONS_DIR
if (-not $dir) { $dir = Join-Path $env:USERPROFILE '.pi\agent\sessions' }
$files = @()
if (Test-Path -LiteralPath $dir) {
    $cutoff = (Get-Date).AddDays(-14)
    foreach ($f in (Get-ChildItem -Path $dir -Filter '*.jsonl' -Recurse -File -ErrorAction SilentlyContinue)) {
        if ($f.Name -notmatch '^(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})-(\d{3})Z') { continue }
        $dt = [DateTime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4], [int]$Matches[5], [int]$Matches[6], [int]$Matches[7], [DateTimeKind]::Utc)
        $ts = [DateTimeOffset]::new($dt)
        if ($ts.LocalDateTime -lt $cutoff) { continue }
        # resumed sessions reuse old files, so match on the newer of
        # filename timestamp and last-write time
        $mtime = [DateTimeOffset]::new($f.LastWriteTime)
        $live = $ts
        if ($mtime.ToUnixTimeSeconds() -gt $ts.ToUnixTimeSeconds()) { $live = $mtime }
        $text = $null
        try {
            foreach ($line in [System.IO.File]::ReadLines($f.FullName)) {
                if ($line -notmatch '"role":"user"') { continue }
                try {
                    $j = $line | ConvertFrom-Json
                    $t = $j.message.content
                    if ($t -is [string]) { $text = $t }
                    else { $text = (($t | ForEach-Object { $_.text }) -join ' ') }
                } catch {}
                break
            }
        } catch {}
        $id = ($f.Name -split '_')[-1].Replace('.jsonl', '')
        $files += [pscustomobject]@{ Ts = $ts; Live = $live; Id = $id; Text = $text }
    }
}

# 1:1 greedy assignment (oldest session first) so labels do not cross-match;
# a closest file more than 1h away is treated as "not this session's file"
$plist = @()   # note: PowerShell vars are case-insensitive, so never name a local $pairs
$i = 0
while ($i + 1 -lt $Pairs.Count) {
    $plist += [pscustomobject]@{ Name = [string]$Pairs[$i]; Ep = [int64]$Pairs[$i + 1] }
    $i += 2
}
$taken = @{}
$results = @{}
foreach ($s in @($plist | Sort-Object { $_.Ep })) {
    $c = [DateTimeOffset]::FromUnixTimeSeconds($s.Ep)
    $best = $null
    $bd = [int64]::MaxValue
    foreach ($p in $files) {
        if ($taken.ContainsKey($p.Id)) { continue }
        $d = [Math]::Abs([int64]($p.Live - $c).TotalSeconds)
        if ($d -lt $bd) { $bd = $d; $best = $p }
    }
    if ($best -and $bd -le 3600 -and $best.Text) {
        $t = (($best.Text -replace '\s+', ' ').Trim())
        if ($t.Length -gt 20) { $t = $t.Substring(0, 20).TrimEnd() + '...'}
        $results[$s.Name] = '"' + $t + '"'
        $taken[$best.Id] = $true
    } else {
        $results[$s.Name] = '(no prompt yet)'
    }
}
$i = 0
while ($i + 1 -lt $Pairs.Count) {
    Write-Output $results[[string]$Pairs[$i]]
    $i += 2
}
