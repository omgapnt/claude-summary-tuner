# Security

Claude Summary Tuner is an unaudited hobby project. Nobody has done a third-party security audit, and the script
is **not code-signed** (`Get-AuthenticodeSignature` reports `NotSigned`). It installs a Bun preload hook that runs
inside Claude Code, so read it before you run it. Everything below can be checked in the source.

## Known issue in v1.0.0 and v1.0.1: other apps' startup entries were removed

**v1.0.0 and v1.0.1 removed every other app's startup entry in your per-user Run key
(`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`) when the logger was turned on.** The script ran
`New-Item <Run key> -Force`. On a registry key that already exists, `-Force` deletes the key and creates an empty
one. Then it wrote its own value, `ClaudeSummaryTunerCollector`, into the empty key.

v1.0.2 fixes this. It creates the Run key only if it does not exist, never with `-Force`, and then sets or removes
only its own value. A test (`test/registry-windows.ps1`) checks this against a scratch key, and a static test fails
if any `New-Item -Force` appears in the script.

An update cannot bring the lost command lines back. To find out what is missing and restore it:

1. Run `.\Claude-Summary-Tuner.ps1 -ListLostStartupApps`. It is read-only. It lists the apps Windows still
   remembers as startup apps (Task Manager > Startup apps) that no longer have a Run value, and whether each one
   was enabled or disabled there.
2. For each app you want back, turn "start with Windows" / "open at login" on again in the app's own settings,
   or repair or reinstall it. Some names may be missing for other reasons, for example an app that was
   uninstalled. The tool does not recreate entries, because it cannot know the original command lines.

## What v1.0.2 can change

| What | Where | When | Undo |
|---|---|---|---|
| Hook file | `%LOCALAPPDATA%\cc-summary-tuner\no-agent-summary.js` (or `-DataDir`). There is no ProgramData fallback any more | any mode | `-Uninstall` |
| Data files | same folder: `config.json`, `actions.jsonl`, `.cst-owned-files.json`, `hook.log`, `collector.ps1`, `collector.pid`, `collector.log(.old)`, `events-*.tsv`, `report-*.html`, `replicate\` | as used | `-Uninstall -DeleteData` (see below) or delete the folder yourself |
| Temp file | `%TEMP%\cst-selftest-<guid>.log`, deleted right away | hook self-test | none needed |
| User env vars | `BUN_OPTIONS` (adds `--preload=<hook>` and keeps your other options), `CC_AGENT_SUMMARY_MODE`, `CC_AGENT_SUMMARY_MIN_DELAY_MS`, `CC_AGENT_SUMMARY_LOG` | any mode | `-Uninstall` |
| User env vars, logger only | `CLAUDE_CODE_ENABLE_TELEMETRY`, `OTEL_LOGS_EXPORTER`, `OTEL_EXPORTER_OTLP_LOGS_PROTOCOL`, `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` (pointing at 127.0.0.1) | only if you turn the logger on | `-Logger off` (removes only values that still match what the tool set) |
| Registry, autostart only | the single value `HKCU\...\CurrentVersion\Run\ClaudeSummaryTunerCollector`. Other Run values are left alone | only if you turn logger autostart on | `-Autostart off`, `-Logger off` or `-Uninstall` |
| Socket, logger only | listens on `127.0.0.1:47318` (or the next free port up to 47367), loopback only | while the logger runs | `-Logger off` |

Processes it starts: `claude.exe --version` (version check and hook self-test, during mode changes and `-Status`);
the logger (`powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File collector.ps1`,
optionally through `conhost --headless`; the policy bypass applies to that process only); `-Replicate` only:
four short `claude -p --model haiku` runs, which cost a few cents of usage; `claude daemon stop --any` only after
you confirm it in the restart check. Processes it stops: only a logger process whose command line runs this
installation's own `collector.ps1` path, and a Replicate run after 15 minutes.

The logger and its autostart are **opt-in** since v1.0.2: without your answer or an explicit `-Logger on` /
`-Autostart on`, nothing listens on a port and nothing starts at logon. If an earlier version already set them up,
they are kept as they are. `-NoLogger` leaves an existing logger alone and never starts, rewrites or autostarts it.
`-Yes` never counts as consent to the logger, to autostart or to deleting data. `-Uninstall -Yes` keeps your data.

`-DeleteData` deletes only files that this version recorded as created by itself (in `.cst-owned-files.json`),
by exact path. It never deletes by wildcard or recursively. Files from v1.0.0/v1.0.1 installs, logger output
(`events-*.tsv`), Replicate output and anything else in the folder are kept. Delete those yourself if you want them
gone.

## What it never does

- No admin rights, no services, no scheduled tasks, no shell-profile changes, no `Set-ExecutionPolicy`.
- No `Invoke-Expression`, no base64 or encoded commands, no compressed code. The hook (`$HookJs`) and the logger
  (`$CollectorPs`) are plain here-strings near the top of the script. The logger only un-gzips request bodies that
  Claude Code may send compressed.
- No downloads, no self-update, no telemetry to the author. The script's only HTTP request goes to its own logger
  at `http://127.0.0.1:<port>/health`, with proxies disabled. In `-Replicate`, Claude Code itself talks to
  Anthropic as it always does.
- It never prints the values of `OTEL_*` variables, or of any variable whose name looks like a header, key,
  token, secret, password or credential. It shows names only.
- The logger keeps per API request only: time, event, session id, model, `query_source`, cost estimate, token
  counts, duration, version, agent name, tag and status. It drops prompts, responses, e-mail and account IDs.
  Claude Code redacts prompt text in telemetry unless `OTEL_LOG_USER_PROMPTS=1`, which this tool never sets.

## Logger limits

- Loopback only. It has no authentication, so any program running on your PC can send it fake events or read
  `/health`.
- Request headers up to 64 KB, bodies up to 8 MB, gzip bodies up to 32 MB after decompression. One 10-second
  deadline per request. Larger, malformed or slow requests are refused.
- Event files stop growing at 128 MB per day and 512 MB in total. The logger then drops new events. It never
  deletes old files, so there is no automatic retention: delete old `events-*.tsv` files yourself.
- Parse errors are logged with a fixed message and never with request content. `collector.log` rotates at 1 MB.

## Other known issues

- **`BUN_OPTIONS` reaches every Bun program.** It is a user-wide variable, so every Bun-based program you start
  loads the hook, not just Claude Code. The hook checks that it runs inside the Claude Code binary (`Bun.main`
  gate) and does nothing otherwise, but it is still loaded.
- **Telemetry variables are user-wide.** When the logger is on, the four variables above apply to every Claude Code
  process of your Windows account.
- **After an upgrade the running logger keeps its old code.** Running your mode again replaces `collector.ps1` on
  disk, but a logger that is already running is not restarted. It runs the old copy until you sign out, or until
  you run `-Logger off` and then `-Logger on` (add `-Autostart on` to keep autostart).
- The data folder must be writable only by you. Do not point `-DataDir` at a shared folder.
- Not signed. Windows SmartScreen and Defender judge it by reputation only.

## Verify before you run it

1. Download `Claude-Summary-Tuner.ps1` and `SHA256SUMS` from the
   [release page](https://github.com/omgapnt/claude-summary-tuner/releases).
2. `Get-FileHash .\Claude-Summary-Tuner.ps1 -Algorithm SHA256` must match the line in `SHA256SUMS`.
3. Or run `.\Claude-Summary-Tuner.ps1 -Verify -ExpectedHash <sha256>`. It is read-only and also checks that the
   hook and logger files on disk equal the copies embedded in the script. It exits with code 1 if anything
   differs. After an upgrade, the logger file on disk differs until you run your mode again.
4. `-WhatIf` (alias `-DryRun`) shows what an action would change. It writes nothing, starts no process and opens
   no socket.
5. `bash src/build.sh --check` rebuilds the single file from `src/` and compares it byte for byte. `src/hook.js`
   is derived from [Flamerix's hook](https://gist.github.com/flamerix-ai/c3905705cc4205e5de3011fa2e74efce)
   (MIT). The only changes are the Windows `Bun.main` gate, the `slow` mode and the slowed counter.

The release notes list what was and was not tested for each version, including whether an antivirus scan was
done. A clean scan or passing tests are evidence, not proof that a program is harmless.

## Reporting a vulnerability

Please do not post exploit details or secrets in a public issue. Use GitHub's private vulnerability reporting on
the repository's Security tab if it is enabled. If it is not, open an issue that only asks for a private contact,
and do not attach real telemetry, logs or credentials.
