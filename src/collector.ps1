# Claude-Summary-Tuner local collector. Receives Claude Code OpenTelemetry log events (OTLP/HTTP JSON)
# on 127.0.0.1 only and appends the cost-relevant fields of api_request / api_error / user_prompt
# events to a daily TSV file. It never stores prompt or response text, e-mail or account ids.
param([Parameter(Mandatory = $true)][string]$DataDir, [Parameter(Mandatory = $true)][int]$Port)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$logFile = Join-Path $DataDir 'collector.log'
function Write-CLog([string]$m) {
  try {
    if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) { Move-Item $logFile "$logFile.old" -Force }
    [IO.File]::AppendAllText($logFile, ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') + " pid=$PID $m`r`n"), $utf8)
  } catch {}
}
$created = $false
$mutex = New-Object System.Threading.Mutex($true, "Local\ClaudeSummaryTunerCollector-$Port", [ref]$created)
if (-not $created) { Write-CLog "another collector already owns port $Port, exiting"; exit 0 }
[IO.File]::WriteAllText((Join-Path $DataDir 'collector.pid'), "$PID", $utf8)
$script:received = 0; $script:stored = 0; $started = (Get-Date).ToUniversalTime().ToString('o')
$Cols = 't', 'event', 'session', 'model', 'query_source', 'cost_usd', 'input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_creation_tokens', 'duration_ms', 'version', 'agent', 'tag', 'status'

function Get-AnyValue($v) {
  if ($null -eq $v) { return $null }
  foreach ($k in 'stringValue', 'intValue', 'doubleValue', 'boolValue') {
    if ($v.PSObject.Properties[$k]) { return $v.$k }
  }
  return $null
}
function Get-Attrs($list) {
  $h = @{}
  if ($list) { foreach ($a in $list) { $h[[string]$a.key] = Get-AnyValue $a.value } }
  return $h
}
function ConvertTo-Field([object]$x) { if ($null -eq $x) { return '' }; return (([string]$x) -replace "[`t`r`n]", ' ') }

function Save-Logs([byte[]]$bytes, [string]$encoding) {
  if ($encoding -match 'gzip') {
    $ms = New-Object IO.MemoryStream(, $bytes); $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Decompress)
    $out = New-Object IO.MemoryStream; $gz.CopyTo($out); $bytes = $out.ToArray(); $gz.Dispose()
  }
  $json = $utf8.GetString($bytes)
  if (-not $json.Trim()) { return }
  $doc = ConvertFrom-Json $json
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($rl in @($doc.resourceLogs)) {
    if ($null -eq $rl) { continue }
    $r = Get-Attrs $rl.resource.attributes
    foreach ($sl in @($rl.scopeLogs)) {
      if ($null -eq $sl) { continue }
      foreach ($lr in @($sl.logRecords)) {
        if ($null -eq $lr) { continue }
        $script:received++
        $a = Get-Attrs $lr.attributes
        $ev = [string]$a['event.name']
        if (-not $ev) { $ev = [string](Get-AnyValue $lr.body) }
        $ev = $ev -replace '^claude_code\.', ''
        if ($ev -notin 'api_request', 'api_error', 'user_prompt') { continue }
        $t = $a['event.timestamp']
        if (-not $t -and $lr.timeUnixNano) { $t = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]([decimal]$lr.timeUnixNano / 1000000)).UtcDateTime.ToString('o') }
        $ver = $r['service.version']; if (-not $ver) { $ver = $a['app.version'] }
        $tag = $a['cc_tuner.tag']; if (-not $tag) { $tag = $r['cc_tuner.tag'] }
        $vals = @($t, $ev, $a['session.id'], $a['model'], $a['query_source'], $a['cost_usd'], $a['input_tokens'], $a['output_tokens'],
          $a['cache_read_tokens'], $a['cache_creation_tokens'], $a['duration_ms'], $ver, $a['agent.name'], $tag, $a['status_code'])
        $lines.Add((($vals | ForEach-Object { ConvertTo-Field $_ }) -join "`t"))
      }
    }
  }
  if ($lines.Count -gt 0) {
    $file = Join-Path $DataDir ('events-' + (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd') + '.tsv')
    $text = ''
    if (-not (Test-Path $file)) { $text = ($Cols -join "`t") + "`r`n" }
    $text += ($lines -join "`r`n") + "`r`n"
    [IO.File]::AppendAllText($file, $text, $utf8)
    $script:stored += $lines.Count
  }
}
function Get-Health { return ('{"ok":true,"app":"claude-summary-tuner","pid":' + $PID + ',"port":' + $Port + ',"started":"' + $started + '","received":' + $script:received + ',"stored":' + $script:stored + '}') }

function Invoke-Route([string]$method, [string]$path, [byte[]]$body, [string]$enc) {
  if ($method -eq 'GET' -and $path -eq '/health') { return @(200, (Get-Health)) }
  if ($method -eq 'POST' -and $path -like '/v1/logs*') {
    try { Save-Logs $body $enc } catch { Write-CLog "parse error: $($_.Exception.Message)" }
    return @(200, '{}')
  }
  if ($method -eq 'POST' -and $path -like '/v1/*') { return @(200, '{}') }  # metrics/traces: accepted and dropped
  return @(404, '{}')
}

$listener = $null; $tcp = $null
for ($try = 0; $try -lt 30 -and -not $listener -and -not $tcp; $try++) {
  try {
    $l = New-Object Net.HttpListener; $l.Prefixes.Add("http://127.0.0.1:$Port/"); $l.Start(); $listener = $l
    Write-CLog "listening (HttpListener) on http://127.0.0.1:$Port/"
  } catch {
    $msg = $_.Exception.Message
    try {
      $t = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port); $t.Start(); $tcp = $t
      Write-CLog "HttpListener failed ($msg); listening (TcpListener) on 127.0.0.1:$Port"
    } catch {
      Write-CLog "port $Port unavailable ($msg / $($_.Exception.Message)); retry in 20 s"
      Start-Sleep -Seconds 20
    }
  }
}
if (-not $listener -and -not $tcp) { Write-CLog 'giving up: could not bind'; exit 1 }

while ($true) {
  try {
    if ($listener) {
      $ctx = $listener.GetContext(); $req = $ctx.Request
      $ms = New-Object IO.MemoryStream; $req.InputStream.CopyTo($ms)
      $res = Invoke-Route $req.HttpMethod $req.Url.AbsolutePath $ms.ToArray() ([string]$req.Headers['Content-Encoding'])
      $out = $utf8.GetBytes([string]$res[1])
      $ctx.Response.StatusCode = [int]$res[0]; $ctx.Response.ContentType = 'application/json'
      $ctx.Response.ContentLength64 = $out.Length; $ctx.Response.OutputStream.Write($out, 0, $out.Length); $ctx.Response.Close()
    } else {
      $client = $tcp.AcceptTcpClient(); $client.ReceiveTimeout = 10000; $ns = $client.GetStream()
      $buf = New-Object byte[] 65536; $acc = New-Object IO.MemoryStream; $hdrEnd = -1
      while ($hdrEnd -lt 0) {
        $n = $ns.Read($buf, 0, $buf.Length); if ($n -le 0) { break }
        $acc.Write($buf, 0, $n); $s = [Text.Encoding]::ASCII.GetString($acc.ToArray()); $hdrEnd = $s.IndexOf("`r`n`r`n")
      }
      if ($hdrEnd -ge 0) {
        $all = $acc.ToArray(); $head = [Text.Encoding]::ASCII.GetString($all, 0, $hdrEnd); $hl = $head -split "`r`n"
        $parts = $hl[0] -split ' '; $len = 0; $enc = ''
        foreach ($h in $hl) { if ($h -match '^(?i)content-length:\s*(\d+)') { $len = [int]$matches[1] }; if ($h -match '^(?i)content-encoding:\s*(.+)$') { $enc = $matches[1] }; if ($h -match '^(?i)expect:\s*100-continue') { $c = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n"); $ns.Write($c, 0, $c.Length) } }
        $body = New-Object IO.MemoryStream; $start = $hdrEnd + 4
        if ($all.Length -gt $start) { $body.Write($all, $start, $all.Length - $start) }
        while ($body.Length -lt $len) { $n = $ns.Read($buf, 0, $buf.Length); if ($n -le 0) { break }; $body.Write($buf, 0, $n) }
        $res = Invoke-Route $parts[0] (($parts[1] -split '\?')[0]) $body.ToArray() $enc
        $out = $utf8.GetBytes([string]$res[1])
        $hdr = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $($res[0]) OK`r`nContent-Type: application/json`r`nContent-Length: $($out.Length)`r`nConnection: close`r`n`r`n")
        $ns.Write($hdr, 0, $hdr.Length); $ns.Write($out, 0, $out.Length)
      }
      $client.Close()
    }
  } catch { Write-CLog "request error: $($_.Exception.Message)"; Start-Sleep -Milliseconds 200 }
}
