# tui.ps1: colored dashboard for keepalive. Loaded by keepalive-launch.ps1 on TTYs.
# Keys: 1-N attach, sN stop, Enter start named, q quit. Redraws in place (no clear).

function Enable-VtOutput {
    # conhost ignores ANSI unless virtual terminal processing is enabled
    try {
        $k = Add-Type -Namespace Win32 -Name Console -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@ -PassThru
        $h = $k.GetStdHandle(-11)
        $mode = 0
        if ($k.GetConsoleMode($h, [ref]$mode)) { $null = $k.SetConsoleMode($h, $mode -bor 0x4) }
    } catch {}
}

function Get-VisibleLength {
    param([string]$s)
    return (($s -replace ('{0}\[[0-9;]*m' -f [char]27), '').Length)
}

function Clip-Visible {
    # trim a colored string to at most $w visible columns (keeps codes intact)
    param([string]$s, [int]$w)
    if ((Get-VisibleLength $s) -le $w) { return $s }
    $out = ''
    $vis = 0
    $i = 0
    while ($i -lt $s.Length -and $vis -lt $w) {
        if ($s[$i] -eq [char]27) {
            $j = $i
            while ($j -lt $s.Length -and $s[$j] -ne 'm') { $j++ }
            if ($j -ge $s.Length) { break }
            $out += $s.Substring($i, $j - $i + 1)
            $i = $j + 1
            continue
        }
        $out += $s[$i]
        $vis++
        $i++
    }
    return $out
}

function Show-TuiDashboard {
    Enable-VtOutput
    $e = [char]27 + '['
    $rst = "${e}0m"; $bold = "${e}1m"; $cyan = "${e}36m"
    $green = "${e}32m"; $yellow = "${e}33m"; $dim = "${e}90m"
    $width = 80
    try { $w = [Console]::WindowWidth; if ($w -ge 40) { $width = $w } } catch {}
    $prevLines = 0
    $first = $true
    while ($true) {
        $all = Get-AllSessions
        $labels = Get-AllLabels -All $all
        $count = $all.Count
        $lines = @()
        $lines += "${cyan}${bold}keepalive${rst}  ${dim}${count} running${rst}"
        if ($count -eq 0) { $lines += "  ${dim}no sessions${rst}" }
        $n = 1
        foreach ($s in $all) {
            $label = ''
            if ($labels.ContainsKey($s.Name)) { $label = "  ${yellow}$($labels[$s.Name])${rst}" }
            $lines += "  ${green}${bold}${n})${rst} ${bold}$($s.Name)${rst}  ${dim}started $($s.Started)${rst}${label}"
            $n++
        }
        $lines += "  ${dim}1-N attach   s1 stop #1   Enter start name   q quit${rst}"
        $prompt = "${bold} > ${rst}"
        # keep the frame at least as tall as the last one, so shrinking
        # (sessions stopped) overwrites every old line
        if (-not $first -and ($lines.Count + 1) -lt $prevLines) {
            while (($lines.Count + 1) -lt $prevLines) { $lines += '' }
        }
        # pad/clip every line so the frame has a stable column width
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $c = Clip-Visible $lines[$i] $width
            $pad = $width - (Get-VisibleLength $c)
            if ($pad -gt 0) { $c += ' ' * $pad }
            $lines[$i] = "${rst}${c}${rst}"
        }
        if ($first) { $first = $false }
        else {
            for ($i = 0; $i -lt $prevLines; $i++) { Write-Host ("${e}1A") -NoNewline }
            Write-Host ("${e}G") -NoNewline   # back to column 0
        }
        foreach ($l in $lines) { Write-Host $l }
        # write the prompt line full-width (clears any previously typed input),
        # then step back to just after the prompt for ReadLine
        $promptFull = $prompt
        $ppad = $width - (Get-VisibleLength $promptFull)
        if ($ppad -gt 0) { $promptFull += ' ' * $ppad }
        Write-Host "${rst}${promptFull}${rst}"
        Write-Host ("${e}1A") -NoNewline
        Write-Host ("${e}4G") -NoNewline
        $prevLines = $lines.Count + 1
        $choice = [Console]::ReadLine()
        if ($null -eq $choice) { exit 0 }
        if ($choice -match '^[qQ]') { exit 0 }
        if ($choice -match '^\s*$') {
            Write-Host "${bold}start: ${rst}"
            $raw = [Console]::ReadLine()
            if ($null -eq $raw -or $raw -match '^\s*$') { continue }
            $rp = Resolve-AdHoc -Name $raw -Args2 @()
            $sname = New-Session -Profile $rp[0] -Args2 $rp[1]
            Invoke-Attach -Name $sname
        }
        if ($choice -match '^\s*s\s?(\d+)\s*$') {
            $idx = [int]$Matches[1]
            if ($idx -ge 1 -and $idx -le $count) {
                $target = $all[$idx - 1]
                [void](Stop-Session -Profile $target.Profile -Name $target.Name)
                continue
            }
        }
        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $count) {
            Invoke-Attach -Name $all[[int]$choice - 1].Name
        }
    }
}
