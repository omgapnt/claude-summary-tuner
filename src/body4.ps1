
# ------------------------------------------------------------------ report
function HtmlEnc([object]$s) { return [System.Net.WebUtility]::HtmlEncode([string]$s) }
function Money([double]$x) { if ($x -ge 100) { return '$' + (Fmt $x '0') }; if ($x -ge 1) { return '$' + (Fmt $x '0.00') }; return '$' + (Fmt $x '0.000') }
function Pct([double]$a, [double]$b) { if ($b -le 0) { return '-' }; return (Fmt (100 * $a / $b) '0.0') + '%' }
function Get-Periods($journal, $events) {
  $acts = @($journal | Where-Object { $_.action -in 'mode', 'uninstall' } | Sort-Object { ParseIso $_.t })
  $now = NowUtc; $periods = @()
  $firstEv = $null; if ($events.Count) { $firstEv = $events[0].t }
  if ($firstEv -and (-not $acts.Count -or $firstEv -lt (ParseIso $acts[0].t))) {
    $end = $now; if ($acts.Count) { $end = ParseIso $acts[0].t }
    $periods += [pscustomobject]@{ label = 'before tuner (no hook)'; mode = 'none'; start = $firstEv; end = $end; confirmed = 'n/a'; ref = $null }
  }
  for ($i = 0; $i -lt $acts.Count; $i++) {
    $a = $acts[$i]; if ($a.action -ne 'mode') { continue }
    $t = ParseIso $a.t; $end = $now; if ($i + 1 -lt $acts.Count) { $end = ParseIso $acts[$i + 1].t }
    $eff = $journal | Where-Object { $_.action -eq 'effective' -and $_.ref -eq $a.t } | Select-Object -First 1
    $start = $t; $conf = 'NOT confirmed (old sessions may still run)'
    if ($eff) { $start = ParseIso $eff.t; $conf = [string]$eff.how }
    if ($start -ge $end) { continue }
    $lbl = $a.mode; if ($a.mode -eq 'slow') { $lbl = "slow $(Fmt ([double]$a.minutes)) min" }
    $periods += [pscustomobject]@{ label = $lbl; mode = $a.mode; start = $start; end = $end; confirmed = $conf; ref = $a.t; changeAt = $t }
  }
  return $periods
}
function Get-PeriodStats($p, $events, $hookRows) {
  $ev = @($events | Where-Object { $_.ev -eq 'api_request' -and $_.t -ge $p.start -and $_.t -lt $p.end })
  $as = @($ev | Where-Object { $_.qs -eq 'agent_summary' })
  $buckets = @{}; foreach ($e in $ev) { $buckets[[int64]([Math]::Floor($e.t.Ticks / 3000000000))] = 1 }   # 5-minute buckets
  $activeH = $buckets.Count * 5 / 60
  $cost = ($ev | Measure-Object cost -Sum).Sum; if (-not $cost) { $cost = 0 }
  $asCost = ($as | Measure-Object cost -Sum).Sum; if (-not $asCost) { $asCost = 0 }
  $hr = @($hookRows | Where-Object { $_.t -ge $p.start -and $_.t -lt $p.end })
  $sup = 0; $slo = 0; $mat = 0
  foreach ($r in $hr) { if ($r.msg -match '^exit: (\d+) summary timer\(s\) suppressed, (?:(\d+) slowed, )?(\d+) matched') { $sup += [int]$matches[1]; if ($matches[2]) { $slo += [int]$matches[2] }; $mat += [int]$matches[3] } }
  $loads = @($hr | Where-Object { $_.msg -like 'preload active*' })
  $modes = ($loads | ForEach-Object { if ($_.msg -match 'mode=(\S+)') { $matches[1] } } | Group-Object | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '
  $vers = (@($ev | Where-Object { $_.ver } | ForEach-Object { $_.ver } | Sort-Object -Unique)) -join ', '
  return [pscustomobject]@{
    p = $p; reqs = $ev.Count; cost = [double]$cost; asReqs = $as.Count; asCost = [double]$asCost; activeH = $activeH
    hours = ($p.end - $p.start).TotalHours; versions = $vers; hookLoads = $loads.Count; hookModes = $modes
    timerLines = @($hr | Where-Object { $_.msg -like 'summary timer #*' }).Count; matched = $mat; suppressed = $sup; slowed = $slo
  }
}
function New-HBarSvg($items, [string]$unit) {
  # items: label, value, color, text
  $w = 760; $rowH = 26; $lw = 230; $h = [Math]::Max(1, $items.Count) * $rowH + 10
  $max = ($items | Measure-Object value -Maximum).Maximum; if (-not $max -or $max -le 0) { $max = 1 }
  $sb = New-Object Text.StringBuilder
  [void]$sb.Append("<svg viewBox='0 0 $w $h' width='100%' style='max-width:${w}px' xmlns='http://www.w3.org/2000/svg' font-family='Segoe UI,Arial' font-size='12'>")
  $y = 5
  foreach ($it in $items) {
    $bw = [Math]::Max(1, ($w - $lw - 120) * $it.value / $max)
    [void]$sb.Append("<text x='$($lw - 8)' y='$(Fmt ($y + 17))' text-anchor='end' fill='#ddd'>$(HtmlEnc $it.label)</text>")
    [void]$sb.Append("<rect x='$lw' y='$(Fmt ($y + 4))' width='$(Fmt $bw)' height='$(Fmt ($rowH - 8))' rx='3' fill='$($it.color)'/>")
    [void]$sb.Append("<text x='$(Fmt ($lw + $bw + 6))' y='$(Fmt ($y + 17))' fill='#bbb'>$(HtmlEnc $it.text)</text>")
    $y += $rowH
  }
  [void]$sb.Append('</svg>'); return $sb.ToString()
}
function New-TimelineSvg($events, $journal, [datetime]$from, [datetime]$to) {
  $span = ($to - $from).TotalHours; $bh = 1; if ($span -gt 48) { $bh = 6 }; if ($span -gt 24 * 14) { $bh = 24 }
  $b0 = New-Object DateTime ($from.Year, $from.Month, $from.Day, 0, 0, 0, [DateTimeKind]::Utc)
  $n = [int][Math]::Ceiling(($to - $b0).TotalHours / $bh); if ($n -lt 1) { $n = 1 }
  $as = New-Object double[] $n; $ot = New-Object double[] $n
  foreach ($e in $events) { if ($e.ev -ne 'api_request') { continue }; $i = [int][Math]::Floor(($e.t - $b0).TotalHours / $bh); if ($i -ge 0 -and $i -lt $n) { if ($e.qs -eq 'agent_summary') { $as[$i] += $e.cost } else { $ot[$i] += $e.cost } } }
  $max = 0.0; for ($i = 0; $i -lt $n; $i++) { if ($as[$i] + $ot[$i] -gt $max) { $max = $as[$i] + $ot[$i] } }; if ($max -le 0) { $max = 1 }
  $W = 960; $Hh = 300; $L = 60; $R = 20; $mTop = 30; $B = 50; $pw = $W - $L - $R; $ph = $Hh - $mTop - $B; $bw = $pw / $n
  $sb = New-Object Text.StringBuilder
  [void]$sb.Append("<svg viewBox='0 0 $W $Hh' width='100%' style='max-width:${W}px' xmlns='http://www.w3.org/2000/svg' font-family='Segoe UI,Arial' font-size='11'>")
  foreach ($g in 0, 0.5, 1) { $yy = $mTop + $ph * (1 - $g); [void]$sb.Append("<line x1='$L' x2='$($W - $R)' y1='$(Fmt $yy)' y2='$(Fmt $yy)' stroke='#333'/><text x='$($L - 6)' y='$(Fmt ($yy + 4))' text-anchor='end' fill='#999'>$(HtmlEnc (Money ($max * $g)))</text>") }
  for ($i = 0; $i -lt $n; $i++) {
    $x = $L + $i * $bw; $h1 = $ph * $ot[$i] / $max; $h2 = $ph * $as[$i] / $max
    if ($h1 -gt 0) { [void]$sb.Append("<rect x='$(Fmt ($x + 0.5))' y='$(Fmt ($mTop + $ph - $h1))' width='$(Fmt ([Math]::Max(0.5, $bw - 1)))' height='$(Fmt $h1)' fill='#5b6b8c'/>") }
    if ($h2 -gt 0) { [void]$sb.Append("<rect x='$(Fmt ($x + 0.5))' y='$(Fmt ($mTop + $ph - $h1 - $h2))' width='$(Fmt ([Math]::Max(0.5, $bw - 1)))' height='$(Fmt $h2)' fill='#ff6b3d'><title>$(HtmlEnc (LocalStr ($b0.AddHours($i * $bh)))): agent_summary $(HtmlEnc (Money $as[$i])), other $(HtmlEnc (Money $ot[$i]))</title></rect>") }
  }
  $ticks = [Math]::Min(8, $n)
  for ($k = 0; $k -le $ticks; $k++) { $i = [int]($n * $k / $ticks); $x = $L + $i * $bw; $d = $b0.AddHours($i * $bh).ToLocalTime(); [void]$sb.Append("<text x='$(Fmt $x)' y='$($Hh - $B + 16)' text-anchor='middle' fill='#999'>$(HtmlEnc $d.ToString('MM-dd HH:mm', $Inv))</text>") }
  $num = 0
  foreach ($a in @($journal | Where-Object { $_.action -in 'mode', 'effective', 'logger_on', 'logger_off', 'uninstall', 'replicate' })) {
    $t = ParseIso $a.t; if ($t -lt $b0 -or $t -gt $b0.AddHours($n * $bh)) { continue }
    $num++; $x = $L + ($t - $b0).TotalHours / $bh * $bw
    $col = @{ mode = '#b388ff'; effective = '#4caf50'; logger_on = '#29b6f6'; logger_off = '#29b6f6'; uninstall = '#ef5350'; replicate = '#ffca28' }[$a.action]
    $txt = $a.action; if ($a.action -eq 'mode') { $txt = "mode: $($a.mode)$(if ($a.mode -eq 'slow') { ' ' + (Fmt ([double]$a.minutes)) + 'm' })" }
    [void]$sb.Append("<line x1='$(Fmt $x)' x2='$(Fmt $x)' y1='$($mTop - 4)' y2='$($mTop + $ph)' stroke='$col' stroke-dasharray='4 3' stroke-width='1.5'><title>$(HtmlEnc (LocalStr $t)) $(HtmlEnc $txt)</title></line><text x='$(Fmt ($x + 3))' y='$(Fmt ($mTop - 8 + ($num % 2) * 11))' fill='$col'>$num</text>")
    $script:markerLegend += "<li><span style='color:$col'>$num</span> $(HtmlEnc (LocalStr $t)) - $(HtmlEnc $txt)</li>"
  }
  [void]$sb.Append("<text x='$L' y='$($Hh - 8)' fill='#999'>bucket = $bh h. Orange = agent_summary, blue-grey = everything else (Claude Code's cost estimate).</text></svg>")
  return $sb.ToString()
}
function New-Report {
  $cfg = Get-Config
  $journal = @(Read-Journal); $events = @(Read-Events | Sort-Object t); $hookRows = Read-HookLog $cfg
  $req = @($events | Where-Object { $_.ev -eq 'api_request' })
  $periods = @(Get-Periods $journal $events)
  $stats = @($periods | ForEach-Object { Get-PeriodStats $_ $events $hookRows })
  # ---- console summary
  Head 'Report'
  if (-not $req.Count) { Warn 'No API requests recorded yet (replicate test runs are not counted here). Is the logger on (-Status)? Did you restart Claude Code after turning it on?' }
  $stats | ForEach-Object {
    $ph = 0; if ($_.activeH -gt 0) { $ph = $_.asCost / $_.activeH }
    [pscustomobject]@{ Period = $_.p.label; From = (LocalStr $_.p.start); 'Active h' = (Fmt $_.activeH '0.0'); Requests = $_.reqs; 'Est. cost' = (Money $_.cost); 'agent_summary reqs' = $_.asReqs; 'agent_summary cost' = (Money $_.asCost); 'Share of cost' = (Pct $_.asCost $_.cost); 'AS $/active h' = (Money $ph) }
  } | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
  # ---- HTML
  $script:markerLegend = ''
  $sb = New-Object Text.StringBuilder
  # v1.0.1: no PC name and no user name in the report, so it can be shared as is (paths are shown as %LOCALAPPDATA% etc.).
  $title = "Claude Code agent_summary report - $(LocalStr (NowUtc))"
  [void]$sb.Append("<!doctype html><html><head><meta charset='utf-8'><title>$(HtmlEnc $title)</title><style>body{background:#14161c;color:#e6e6e6;font:14px/1.5 'Segoe UI',Arial,sans-serif;margin:24px auto;max-width:1040px;padding:0 16px}h1{font-size:22px}h2{font-size:17px;margin-top:32px;border-bottom:1px solid #333;padding-bottom:4px}table{border-collapse:collapse;width:100%;margin:8px 0}th,td{border-bottom:1px solid #2a2d36;padding:5px 8px;text-align:right;font-variant-numeric:tabular-nums}th{color:#aab;font-weight:600;background:#1b1e26;font-size:12px}table{font-size:13px}td:first-child,th:first-child{text-align:left}.warn{color:#ffca28}.muted{color:#8a8f9c}.card{display:inline-block;background:#1b1e26;border-radius:8px;padding:10px 16px;margin:4px 8px 4px 0}.card b{font-size:20px;display:block}code{background:#222;padding:1px 4px;border-radius:3px}ul{margin:4px 0}</style></head><body>")
  [void]$sb.Append("<h1>$(HtmlEnc $title)</h1><p class='muted'>Generated by $ToolName $ToolVersion. Data folder: <code>$(HtmlEnc (Hide-UserPaths $DataDir))</code>. Times are local ($(HtmlEnc ([TimeZoneInfo]::Local.Id))).</p>")
  $tc = ($req | Measure-Object cost -Sum).Sum; if (-not $tc) { $tc = 0 }
  $asAll = @($req | Where-Object { $_.qs -eq 'agent_summary' }); $ac = ($asAll | Measure-Object cost -Sum).Sum; if (-not $ac) { $ac = 0 }
  [void]$sb.Append("<div><span class='card'>API requests<b>$($req.Count)</b></span><span class='card'>Est. cost<b>$(HtmlEnc (Money $tc))</b></span><span class='card'>agent_summary requests<b>$($asAll.Count) ($(Pct $asAll.Count $req.Count))</b></span><span class='card'>agent_summary est. cost<b>$(HtmlEnc (Money $ac)) ($(Pct $ac $tc))</b></span></div>")
  [void]$sb.Append("<h2>Periods (split at the moments each change took effect)</h2><table><tr><th>Period</th><th>From</th><th>To</th><th>Effective?</th><th>Active h</th><th>Requests</th><th>Est. cost</th><th>agent_summary reqs</th><th>agent_summary cost</th><th>share of cost</th><th>share of reqs</th><th>AS reqs / active h</th><th>AS $ / active h</th><th>total $ / active h</th><th>CC versions</th></tr>")
  foreach ($s in $stats) {
    $ah = $s.activeH; $f = { param($x) if ($ah -gt 0) { $x / $ah } else { 0 } }
    [void]$sb.Append("<tr><td>$(HtmlEnc $s.p.label)</td><td>$(HtmlEnc (LocalStr $s.p.start))</td><td>$(HtmlEnc (LocalStr $s.p.end))</td><td>$(HtmlEnc $s.p.confirmed)</td><td>$(Fmt $ah '0.0')</td><td>$($s.reqs)</td><td>$(HtmlEnc (Money $s.cost))</td><td>$($s.asReqs)</td><td>$(HtmlEnc (Money $s.asCost))</td><td>$(Pct $s.asCost $s.cost)</td><td>$(Pct $s.asReqs $s.reqs)</td><td>$(Fmt (& $f $s.asReqs) '0.0')</td><td>$(HtmlEnc (Money (& $f $s.asCost)))</td><td>$(HtmlEnc (Money (& $f $s.cost)))</td><td>$(HtmlEnc $s.versions)</td></tr>")
  }
  [void]$sb.Append("</table><p class='muted'>Active hour = 5-minute slots with at least one API request, so idle nights do not dilute the comparison. Requests between a change and the moment it took effect (old sessions still running) are left out. Replicate test runs are left out.</p>")
  if ($stats.Count) {
    $items = @($stats | ForEach-Object { $v = 0; if ($_.activeH -gt 0) { $v = $_.asCost / $_.activeH }; [pscustomobject]@{ label = $_.p.label; value = $v; color = '#ff6b3d'; text = "$(Money $v) per active h ($(Pct $_.asCost $_.cost) of cost)" } })
    [void]$sb.Append('<h2>agent_summary cost per active hour, by period</h2>' + (New-HBarSvg $items '$'))
  }
  if ($req.Count) {
    [void]$sb.Append('<h2>Timeline</h2>' + (New-TimelineSvg $events $journal $req[0].t (NowUtc)) + "<ul class='muted'>$($script:markerLegend)</ul>")
    foreach ($dim in @(@('qs', 'query_source (what the request was for)'), @('model', 'model'))) {
      $g = @($req | Group-Object { $v = $_.($dim[0]); if ($v) { $v } else { '(none)' } } | ForEach-Object { [pscustomobject]@{ k = $_.Name; n = $_.Count; c = [double](($_.Group | Measure-Object cost -Sum).Sum); i = [double](($_.Group | Measure-Object inTok -Sum).Sum); cr = [double](($_.Group | Measure-Object cr -Sum).Sum); cw = [double](($_.Group | Measure-Object cw -Sum).Sum); o = [double](($_.Group | Measure-Object outTok -Sum).Sum) } } | Sort-Object c -Descending)
      [void]$sb.Append("<h2>Share by $(HtmlEnc $dim[1]) - all periods</h2>")
      $items = @($g | Select-Object -First 12 | ForEach-Object { $col = '#5b6b8c'; if ($_.k -eq 'agent_summary') { $col = '#ff6b3d' }; [pscustomobject]@{ label = $_.k; value = $_.c; color = $col; text = "$(Money $_.c) ($(Pct $_.c $tc)), $($_.n) reqs ($(Pct $_.n $req.Count))" } })
      [void]$sb.Append((New-HBarSvg $items '$'))
      [void]$sb.Append('<table><tr><th>' + (HtmlEnc $dim[0]) + '</th><th>requests</th><th>% reqs</th><th>est. cost</th><th>% cost</th><th>input</th><th>cache read</th><th>cache write</th><th>output</th></tr>')
      foreach ($r in $g) { [void]$sb.Append("<tr><td>$(HtmlEnc $r.k)</td><td>$($r.n)</td><td>$(Pct $r.n $req.Count)</td><td>$(HtmlEnc (Money $r.c))</td><td>$(Pct $r.c $tc)</td><td>$(Fmt $r.i '0')</td><td>$(Fmt $r.cr '0')</td><td>$(Fmt $r.cw '0')</td><td>$(Fmt $r.o '0')</td></tr>") }
      [void]$sb.Append('</table>')
    }
  }
  [void]$sb.Append("<h2>Hook evidence (from the hook log)</h2><table><tr><th>Period</th><th>hook loads (processes)</th><th>modes seen</th><th>timer lines logged</th><th>matched (at exit)</th><th>slowed</th><th>suppressed</th></tr>")
  foreach ($s in $stats) { [void]$sb.Append("<tr><td>$(HtmlEnc $s.p.label)</td><td>$($s.hookLoads)</td><td>$(HtmlEnc $s.hookModes)</td><td>$($s.timerLines)</td><td>$($s.matched)</td><td>$($s.slowed)</td><td>$($s.suppressed)</td></tr>") }
  [void]$sb.Append("</table><p class='muted'>Each Claude Code process writes one 'preload active' line when the hook loads and a total when it exits. A period in slow/off mode with hook loads but zero matched timers while agents ran means the hook no longer recognises the summary timer (fail-open).</p>")
  $reps = @(Get-ChildItem -LiteralPath (Join-Path $DataDir 'replicate') -Filter 'results.json' -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName)
  if ($reps.Count) {
    [void]$sb.Append("<h2>Replicate runs (Flamerix 'Tested versions' protocol)</h2><table><tr><th>When</th><th>version</th><th>sha256</th><th>static</th><th>summary forks: no hook / pass / off</th><th>timer fired</th><th>slow arm</th><th>agent_summary requests (telemetry)</th><th>est. cost</th><th>debug files</th></tr>")
    foreach ($f in $reps) {
      try { $r = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
      [void]$sb.Append("<tr><td>$(HtmlEnc (LocalStr (ParseIso $r.t)))</td><td>$(HtmlEnc $r.version)</td><td><code>$(HtmlEnc $r.sha12)</code></td><td>$(HtmlEnc $r.static)</td><td><b>$(HtmlEnc $r.forks)</b></td><td>$(HtmlEnc $r.fired)</td><td>$(HtmlEnc $r.slow)</td><td>$(HtmlEnc $r.telemetry)</td><td>$(HtmlEnc $r.cost)</td><td class='muted' style='text-align:left'>$(HtmlEnc (Hide-UserPaths $f.DirectoryName))</td></tr>")
    }
    [void]$sb.Append("</table><p class='muted'>Flamerix's published row for 2.1.312: 5 / 5 / 0.</p>")
  }
  [void]$sb.Append('<h2>Action journal</h2><table><tr><th>When</th><th>Action</th><th>Details</th></tr>')
  foreach ($a in $journal) { $d = ($a.PSObject.Properties | Where-Object { $_.Name -notin 't', 'action', 'bun_options' -and $null -ne $_.Value -and "$($_.Value)" -ne '' } | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; '; [void]$sb.Append("<tr><td>$(HtmlEnc (LocalStr (ParseIso $a.t)))</td><td>$(HtmlEnc $a.action)</td><td style='text-align:left'>$(HtmlEnc (Hide-UserPaths $d))</td></tr>") }
  [void]$sb.Append("</table><h2>Caveats</h2><ul><li><b>cost_usd is Claude Code's own estimate</b> at API list prices, not an invoice. On a Pro/Max subscription it stands for rate-limit headroom you use up, not money.</li><li>Periods differ in workload. Compare per-active-hour numbers and the agent_summary <i>share</i>, and collect a few days per period. The summary only runs while background agents/subagents run.</li><li><b>Fail-open:</b> a Claude Code update can rename what the hook looks for. Then summaries silently come back. Check the CC versions column, the hook evidence table and run <code>-Status</code> / <code>-Replicate</code> after updates.</li><li>Processes that started before a change keep the old setting; periods start only when none was left (or when you confirmed). The Claude desktop app's Code tab runs its own bundled Claude Code (in %APPDATA%\Claude\claude-code), which inherits BUN_OPTIONS from the app; the app must be fully quit and reopened after a change. Cowork mode runs in its own VM and is probably not covered.</li><li>The logger stores only: time, event type, session id, model, query_source, token counts, cost estimate, duration, Claude Code version and agent type. No prompts, responses, e-mail or account ids. Only what reaches 127.0.0.1 on this PC.</li><li>Unofficial tool; changing client behaviour may conflict with the service terms. Hook (c) Flamerix AI, MIT.</li></ul></body></html>")
  $out = $ReportTo; if (-not $out) { $out = Join-Path $DataDir ('report-' + (Get-Date).ToString('yyyyMMdd-HHmm', $Inv) + '.html') }
  Ensure-Dir (Split-Path $out -Parent); Write-Text $out (Hide-UserPaths $sb.ToString())   # safety net for any path left
  Good "  HTML report: $out"
  if (-not $NoOpen -and -not $script:DryRun) { try { Invoke-Item -LiteralPath $out } catch {} }
  return $out
}
