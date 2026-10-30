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
$MaxBody = 8MB        # v1.0.2: larger request bodies are refused (413)
$MaxInflated = 32MB   # and gzip bodies may not expand beyond this
$MaxDaily = 128MB     # fail closed on event storage growth; never delete files by wildcard
$MaxTotal = 512MB
$MaxRequestMs = 10000
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
    $out = New-Object IO.MemoryStream; $buf = New-Object byte[] 65536
    try { while (($n = $gz.Read($buf, 0, $buf.Length)) -gt 0) { $out.Write($buf, 0, $n); if ($out.Length -gt $MaxInflated) { throw 'gzip body too large after decompression, dropped' } } }
    finally { $gz.Dispose() }
    $bytes = $out.ToArray()
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
    if (-not (Test-Path $file) -or (Get-Item -LiteralPath $file).Length -eq 0) { $text = ($Cols -join "`t") + "`r`n" }
    $text += ($lines -join "`r`n") + "`r`n"
    $incoming = $utf8.GetByteCount($text)
    $daily = 0; if (Test-Path -LiteralPath $file) { $daily = (Get-Item -LiteralPath $file).Length }
    $total = [long](@(Get-ChildItem -LiteralPath $DataDir -Filter 'events-*.tsv' -File | Measure-Object Length -Sum)[0].Sum)
    if ($daily + $incoming -gt $MaxDaily -or $total + $incoming -gt $MaxTotal) { throw 'event storage quota reached' }
    [IO.File]::AppendAllText($file, $text, $utf8)
    $script:stored += $lines.Count
  }
}
function Get-Health { return ('{"ok":true,"app":"claude-summary-tuner","pid":' + $PID + ',"port":' + $Port + ',"started":"' + $started + '","received":' + $script:received + ',"stored":' + $script:stored + '}') }

function Invoke-Route([string]$method, [string]$path, [byte[]]$body, [string]$enc) {
  if ($method -eq 'GET' -and $path -eq '/health') { return @(200, (Get-Health)) }
  if ($method -eq 'POST' -and $path -like '/v1/logs*') {
    try { Save-Logs $body $enc } catch { Write-CLog 'invalid or oversized telemetry, dropped'; return @(400, '{}') }
    return @(200, '{}')
  }
  if ($method -eq 'POST' -and $path -like '/v1/*') { return @(200, '{}') }  # metrics/traces: accepted and dropped
  return @(404, '{}')
}

function Read-RequestBytes($stream, [byte[]]$buffer, [int]$offset, [int]$count, $clock) {
  $remaining = $MaxRequestMs - [int]$clock.ElapsedMilliseconds
  if ($remaining -le 0) { throw 'request deadline exceeded' }
  $stream.ReadTimeout = $remaining
  return $stream.Read($buffer, $offset, $count)
}
function Read-HeaderLine($stream, $clock, [int]$limit = 8192) {
  $line = New-Object IO.MemoryStream; $one = New-Object byte[] 1
  try {
    while ($line.Length -lt $limit) {
      if ((Read-RequestBytes $stream $one 0 1 $clock) -eq 0) { throw 'incomplete line' }
      $line.WriteByte($one[0])
      if ($one[0] -eq 10) {
        $bytes = $line.ToArray()
        if ($bytes.Length -lt 2 -or $bytes[$bytes.Length - 2] -ne 13) { throw 'bad line ending' }
        return [Text.Encoding]::ASCII.GetString($bytes, 0, $bytes.Length - 2)
      }
    }
    throw 'line too long'
  } finally { $line.Dispose() }
}
function Read-ChunkedBody($stream, $clock) {
  $body = New-Object IO.MemoryStream; $buf = New-Object byte[] 65536
  try {
    while ($true) {
      $line = Read-HeaderLine $stream $clock
      $sizeText = ($line -split ';', 2)[0]; $size = [long]0
      if ($sizeText -notmatch '^[0-9A-Fa-f]{1,8}$' -or -not [long]::TryParse($sizeText, [Globalization.NumberStyles]::HexNumber, [Globalization.CultureInfo]::InvariantCulture, [ref]$size)) { throw 'invalid chunk length' }
      if ($body.Length + $size -gt $MaxBody) { throw 'chunked body too large' }
      if ($size -eq 0) {
        $trailerBytes = 0
        do { $trailer = Read-HeaderLine $stream $clock; $trailerBytes += $trailer.Length + 2; if ($trailerBytes -gt 65536) { throw 'trailers too large' } } while ($trailer)
        return ,$body.ToArray()
      }
      $left = $size
      while ($left -gt 0) {
        $n = Read-RequestBytes $stream $buf 0 ([int][Math]::Min($buf.Length, $left)) $clock
        if ($n -eq 0) { throw 'incomplete chunk' }; $body.Write($buf, 0, $n); $left -= $n
      }
      if ((Read-HeaderLine $stream $clock 2) -ne '') { throw 'missing chunk separator' }
    }
  } finally { $body.Dispose() }
}
$tcp = $null
for ($attempt = 0; $attempt -lt 30 -and -not $tcp; $attempt++) {
  $candidate = $null
  try {
    $candidate = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
    $candidate.Start(); $tcp = $candidate
    Write-CLog "listening on 127.0.0.1:$Port"
  } catch {
    if ($candidate) { $candidate.Stop() }
    Write-CLog 'loopback port unavailable; retrying in 20 seconds'
    Start-Sleep -Seconds 20
  }
}
if (-not $tcp) { Write-CLog 'giving up: could not bind loopback port'; exit 1 }
try {
  while ($true) {
    $client = $null; $ns = $null; $acc = $null
    try {
      $client = $tcp.AcceptTcpClient(); $ns = $client.GetStream(); $ns.WriteTimeout = 2000
      $clock = [Diagnostics.Stopwatch]::StartNew()
      $acc = New-Object IO.MemoryStream; $one = New-Object byte[] 1; $tail = ''
      # Read only the header, up to 64 KiB, without consuming any unframed body bytes.
      while ($tail -ne "`r`n`r`n") {
        if ($acc.Length -ge 65536) { throw 'header too large' }
        $n = Read-RequestBytes $ns $one 0 1 $clock
        if ($n -eq 0) { throw 'incomplete header' }
        $acc.WriteByte($one[0]); $tail += [char]$one[0]
        if ($tail.Length -gt 4) { $tail = $tail.Substring($tail.Length - 4) }
      }
      $head = [Text.Encoding]::ASCII.GetString($acc.ToArray())
      $hl = $head -split "`r`n"; $parts = $hl[0] -split ' '
      if ($parts.Count -ne 3 -or $parts[2] -notmatch '^HTTP/1\.[01]$') { throw 'bad request line' }
      $len = [long]0; $seenLength = $false; $enc = ''; $expect = $false; $chunked = $false
      foreach ($h in $hl | Select-Object -Skip 1) {
        if ($h -match '^(?i)transfer-encoding:\s*(.*?)\s*$') {
          if ($chunked -or $matches[1] -ne 'chunked') { throw 'unsupported transfer encoding' }; $chunked = $true
        }
        if ($h -match '^(?i)content-length:\s*(.*?)\s*$') {
          $lengthText = $matches[1]
          if ($seenLength -or $lengthText -notmatch '^\d+$' -or -not [long]::TryParse($lengthText, [ref]$len)) { throw 'bad content length' }
          $seenLength = $true
        }
        if ($h -match '^(?i)content-encoding:\s*(.+)$') { $enc = $matches[1].Trim() }
        if ($h -match '^(?i)expect:\s*100-continue\s*$') { $expect = $true }
      }
      if ($chunked -and $seenLength) { throw 'ambiguous body framing' }
      if ($parts[0] -eq 'POST' -and -not ($seenLength -or $chunked)) { $res = @(411, '{}') }
      elseif ($len -gt $MaxBody) { Write-CLog 'request over body cap, refused'; $res = @(413, '{}') }
      else {
        if ($expect) { $interim = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n"); $ns.Write($interim, 0, $interim.Length) }
        if ($chunked) { $body = Read-ChunkedBody $ns $clock }
        else {
          $body = New-Object byte[] ([int]$len); $read = 0
          while ($read -lt $len) {
            $n = Read-RequestBytes $ns $body $read ([Math]::Min(65536, [int]$len - $read)) $clock
            if ($n -eq 0) { throw 'incomplete body' }; $read += $n
          }
        }
        if ($enc -and $enc -ne 'gzip' -and $enc -ne 'identity') { $res = @(415, '{}') }
        else { $res = Invoke-Route $parts[0] (($parts[1] -split '\?')[0]) $body $enc }
      }
      $out = $utf8.GetBytes([string]$res[1])
      $hdr = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $($res[0]) Result`r`nContent-Type: application/json`r`nContent-Length: $($out.Length)`r`nConnection: close`r`n`r`n")
      $ns.Write($hdr, 0, $hdr.Length); $ns.Write($out, 0, $out.Length)
    } catch { Write-CLog 'invalid, incomplete, or timed-out request, dropped' }
    finally {
      if ($acc) { $acc.Dispose() }; if ($ns) { $ns.Dispose() }; if ($client) { $client.Close() }
    }
  }
} finally { $tcp.Stop(); $mutex.Dispose() }
