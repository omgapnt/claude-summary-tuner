"""Run only the extracted fixed collector against synthetic loopback traffic.

Never runs the installer, changes startup/environment settings, or calls Claude.
All runtime artifacts are kept in a unique directory under --test-root.
"""
import argparse
import gzip
import json
from pathlib import Path
import socket
import subprocess
import time
import uuid

p = argparse.ArgumentParser()
p.add_argument('--host', required=True)
p.add_argument('--test-root', type=Path, required=True)
args = p.parse_args()
root = args.test_root.resolve() / ('collector-' + uuid.uuid4().hex)
root.mkdir(parents=True)
candidate = Path(__file__).resolve().parent.parent / 'Claude-Summary-Tuner.ps1'
text = candidate.read_text(encoding='utf-8-sig')
collector = text.split("$CollectorPs = @'\n", 1)[1].split("\n'@", 1)[0]
script = root / 'collector.ps1'
script.write_text(collector, encoding='utf-8')
with socket.socket() as probe:
    probe.bind(('127.0.0.1', 0))
    port = probe.getsockname()[1]

checks = 0
def check(condition, description):
    global checks
    if not condition:
        raise AssertionError(description)
    checks += 1
    print('PASS: ' + description, flush=True)

def request(body=b'', method='POST', path='/v1/logs', extra=b'', length=None, chunked=False):
    framing = b'Transfer-Encoding: chunked\r\n' if chunked else f'Content-Length: {len(body) if length is None else length}\r\n'.encode()
    head = f'{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n'.encode() + framing
    if chunked:
        middle = len(body) // 2
        body = b''.join(f'{len(piece):x};test=extension\r\n'.encode() + piece + b'\r\n' for piece in [body[:middle], body[middle:]]) + b'0\r\nX-Test: trailer\r\n\r\n'
    with socket.create_connection(('127.0.0.1', port), timeout=3) as sock:
        sock.settimeout(15)
        sock.sendall(head + extra + b'\r\n' + body)
        data = b''
        while True:
            part = sock.recv(65536)
            if not part:
                return data
            data += part
            if b'\r\n\r\n' in data:
                headers, payload = data.split(b'\r\n\r\n', 1)
                lengths = [int(line.split(b':', 1)[1].strip()) for line in headers.split(b'\r\n') if line.lower().startswith(b'content-length:')]
                if lengths and len(payload) >= lengths[0]:
                    return data

out = (root / 'stdout.txt').open('wb')
err = (root / 'stderr.txt').open('wb')
proc = subprocess.Popen([args.host, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(script), '-DataDir', str(root), '-Port', str(port)], stdout=out, stderr=err, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
try:
    deadline = time.monotonic() + 15
    while True:
        if proc.poll() is not None:
            raise RuntimeError('Collector exited: ' + (root / 'stderr.txt').read_text(errors='replace'))
        try:
            health = request(method='GET', path='/health')
            if b'200' in health.split(b'\r\n')[0]:
                break
        except (OSError, TimeoutError):
            pass
        if time.monotonic() > deadline:
            raise TimeoutError('Collector failed to bind loopback')
        time.sleep(.1)
    check(b'claude-summary-tuner' in health, 'collector responds to loopback health')
    attrs = [{'key': 'event.name', 'value': {'stringValue': 'api_request'}},
             {'key': 'event.timestamp', 'value': {'stringValue': '2026-10-30T12:00:00Z'}},
             {'key': 'model', 'value': {'stringValue': 'synthetic-model'}},
             {'key': 'query_source', 'value': {'stringValue': 'agent_summary'}},
             {'key': 'prompt', 'value': {'stringValue': 'PROMPT-SECRET-MUST-NOT-PERSIST'}}]
    event = json.dumps({'resourceLogs': [{'scopeLogs': [{'logRecords': [{'attributes': attrs}]}]}]}).encode()
    check(b'200' in request(event).split(b'\r\n')[0], 'valid synthetic OTLP is accepted')
    data = '\n'.join(f.read_text() for f in root.glob('events-*.tsv'))
    check('synthetic-model' in data and 'PROMPT-SECRET' not in data, 'event allowlist stores cost fields without prompt')
    check(b'200' in request(gzip.compress(event), extra=b'Content-Encoding: gzip\r\n').split(b'\r\n')[0], 'gzip OTLP is accepted')
    check(b'200' in request(event, chunked=True).split(b'\r\n')[0], 'chunked OTLP with extensions and trailers is accepted')
    check(b'200' in request(gzip.compress(event), extra=b'Content-Encoding: gzip\r\n', chunked=True).split(b'\r\n')[0], 'chunked gzip OTLP is accepted')
    secret = b'{"malformed": "PARSER-SECRET-MUST-NOT-PERSIST",'
    check(b'400' in request(secret).split(b'\r\n')[0], 'malformed JSON is rejected without parser diagnostics')
    check('PARSER-SECRET' not in (root / 'collector.log').read_text(), 'parser sentinel never enters collector.log')
    check(b'413' in request(length=8 * 1024 * 1024 + 1).split(b'\r\n')[0], 'oversized declared body rejected before reading it')
    bomb = gzip.compress(b' ' * (32 * 1024 * 1024 + 1))
    check(b'400' in request(bomb, extra=b'Content-Encoding: gzip\r\n').split(b'\r\n')[0], 'oversized decompressed body rejected')
    check(b'415' in request(event, extra=b'Content-Encoding: br\r\n').split(b'\r\n')[0], 'unsupported compression is rejected')
    # A slow sender must not extend a request indefinitely by sending one byte per timeout.
    with socket.create_connection(('127.0.0.1', port), timeout=3) as slow:
        slow.sendall(b'POST /v1/logs HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 100\r\n\r\n{')
        started = time.monotonic()
        slow.settimeout(13)
        check(slow.recv(1) == b'' and time.monotonic() - started < 13, 'incomplete body is disconnected by total request deadline')
    check(b'200' in request(method='GET', path='/health').split(b'\r\n')[0], 'collector recovers after slow client')
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)
    out.close()
    err.close()

# Quota checks run the collector's own parsing functions in a child without opening a listener.
prefix = collector[:collector.index('$created = $false')]
helpers = collector[collector.index('function Get-AnyValue'):collector.index('function Get-Health')]
quota = root / 'quota.ps1'
quota.write_text(prefix + '\n$MaxInflated=32MB; $MaxDaily=1; $MaxTotal=512MB; $script:received=0; $script:stored=0;\n' +
                 "$Cols='t','event','session','model','query_source','cost_usd','input_tokens','output_tokens','cache_read_tokens','cache_creation_tokens','duration_ms','version','agent','tag','status'\n" + helpers +
                 '\n$bytes=[IO.File]::ReadAllBytes((Join-Path $DataDir "event.json"));\n' +
                 "try { Save-Logs $bytes ''; throw 'quota was not enforced' } catch { if ($_.Exception.Message -ne 'event storage quota reached') { throw } };\n" +
                 "$MaxDaily=128MB; $MaxTotal=1; try { Save-Logs $bytes ''; throw 'quota was not enforced' } catch { if ($_.Exception.Message -ne 'event storage quota reached') { throw } }; 'QUOTAS OK'\n", encoding='utf-8')
(root / 'event.json').write_bytes(event)
result = subprocess.run([args.host, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(quota), '-DataDir', str(root), '-Port', str(port)], capture_output=True, text=True, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
check(result.returncode == 0 and 'QUOTAS OK' in result.stdout, 'daily and total storage quotas are enforced by real Save-Logs code')
print(f'COLLECTOR INTEGRATION: {checks} passed. Artifacts: {root}', flush=True)
