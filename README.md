<div align="center">

# Claude Summary Tuner

### Claude Code re-sends your whole subagent transcript every ~30 s to draw a 3-word status line.<br>Measure what that costs you on Windows, then slow it down or switch it off.

[![PowerShell 5.1 | 7](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE?logo=powershell&logoColor=white)](#quick-start)
[![Windows](https://img.shields.io/badge/Windows-0078D6?logo=windows&logoColor=white)](#quick-start)
[![Claude Code 2.1.312 tested](https://img.shields.io/badge/Claude%20Code-2.1.312%20tested-D97757)](#replicate-the-flamerix-test)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**One file · no admin · no Node · fully undoable · measure first, then change**

<img src="docs/img/report-hero.png" alt="HTML report comparing a baseline period with a 'slow 5 min' period" width="820">

<sub>The built-in HTML report. <b>The screenshot uses the synthetic test data from <code>test/unit.ps1</code></b>, not a real measurement. Your numbers come from your own usage.</sub>

</div>

---

## The problem in 30 seconds

- While a **subagent or background agent** runs, Claude Code (since v2.1.232) starts a side request about every
  **30 seconds**. The side request is tagged `query_source = agent_summary`.
- Each one sends that agent's **entire transcript** to the agent's model, often Opus, and asks for a
  *"3-5 word"* description. The answer only updates the status text in the agents panel.
- [Flamerix AI measured](https://gist.github.com/flamerix-ai/c3905705cc4205e5de3011fa2e74efce) these requests at
  **16.4 % of all Claude Code spend** over one week, which was more than their main conversation (15.7 %).
  [anthropics/claude-code#86879](https://github.com/anthropics/claude-code/issues/86879) collects other reports of
  18-26 %. Your share depends on how much you use agents.
- There is **no setting** to turn it off. Flamerix published a small Bun `--preload` hook that does. It was
  tested on Linux and reported working on macOS, but **its gate never fires on Windows**. On Windows, Bun's
  `Bun.main` is `B:/~BUN/root/cli`, not `/$bunfs/root/cli`.

**This repo makes it work on Windows and adds a way to measure it.** It is one PowerShell script that:

| | |
|---|---|
| 🪟 **Windows support** | Ships Flamerix's hook with a Windows path gate, installed through the `BUN_OPTIONS` user variable |
| 🐢 **Slow mode** | Keeps the status line, but updates it at most every 5 minutes, or every N minutes you choose |
| 📈 **Local logger** | Records Claude Code's own OpenTelemetry `api_request` events by `query_source` on 127.0.0.1 |
| 🗒️ **Action journal** | Timestamps every change and the moment it *actually* took effect, once all old sessions are gone |
| 📊 **HTML report** | Compares before and after per active hour, with inline SVG charts and no internet needed |
| 🔬 **Replicate mode** | Re-runs Flamerix's A/B test on your machine for about $0.03 of Haiku |

## Quick start

In PowerShell (Windows PowerShell 5.1 or PowerShell 7, **no admin**):

```powershell
irm https://raw.githubusercontent.com/omgapnt/claude-summary-tuner/main/Claude-Summary-Tuner.ps1 -OutFile Claude-Summary-Tuner.ps1
powershell -ExecutionPolicy Bypass -File .\Claude-Summary-Tuner.ps1
```

Pick an option from the menu. Then **close and restart every Claude Code session** (see
[Restart everything](#-restart-everything-after-every-change)).

> Read the script before you run it. It is one plain-text file, and the hook is embedded near the top as `$HookJs`.

## Modes

| # | Menu item | What happens | Agent panel status |
|---|---|---|---|
| 1 | **Baseline** | Hook installed in `pass` mode: it only counts summary timers and changes nothing. The logger starts. | unchanged (~30 s) |
| 2 | **Slow 5 min** | Each summary timer waits at least 5 minutes | updates every ≥ 5 min |
| 3 | **Custom minutes** | Like Slow, with your own interval (≥ 0.5 min, decimals OK, e.g. `2.5`) | updates every ≥ N min |
| 4 | **Off** | Summary timers are dropped, so no `agent_summary` requests | stops updating |
| 5 | Status | Mode, env vars, logger, and which running Claude processes have the hook loaded | |
| 6 | Restart check | Lists Claude processes still running from before the last change | |
| 7 | Report | Builds and opens the HTML report | |
| 8 | Replicate | Flamerix's A/B protocol, four short Haiku runs (see below) | |
| 9 | Logger on/off | Starts or stops the local telemetry logger | |
| 10 | Uninstall | Removes everything and asks whether to keep your data | |

Command line equivalents:

```powershell
.\Claude-Summary-Tuner.ps1 -Mode baseline
.\Claude-Summary-Tuner.ps1 -Mode slow                  # 5 minutes
.\Claude-Summary-Tuner.ps1 -Mode custom -Minutes 2.5
.\Claude-Summary-Tuner.ps1 -Mode off
.\Claude-Summary-Tuner.ps1 -Status
.\Claude-Summary-Tuner.ps1 -CheckRestart
.\Claude-Summary-Tuner.ps1 -Report [-ReportTo C:\path\report.html] [-NoOpen]
.\Claude-Summary-Tuner.ps1 -Replicate [-ReplicateSlowMinutes 1] [-Yes]
.\Claude-Summary-Tuner.ps1 -Logger on|off
.\Claude-Summary-Tuner.ps1 -Uninstall [-KeepData | -DeleteData]
```

## The recommended experiment: baseline → switch → report

```text
 day 0           day 2-3                       day 5-6
   │                │                              │
   ▼                ▼                              ▼
[1 Baseline] ── use Claude normally ──▶ [2 Slow / 3 Custom / 4 Off] ── use Claude normally ──▶ [7 Report]
   restart all sessions                    restart all sessions
```

1. Choose **1 Baseline** and restart every Claude Code session. Then work as usual for a few days.
2. Choose **2 Slow**, **3 Custom** or **4 Off**, and restart every session again. Then work as usual for a few more days.
3. Choose **7 Report**. For each period, the report shows `agent_summary` requests, Claude Code's cost estimate
   and the share of total spend, all **per active hour**. Idle nights do not dilute the comparison. It also
   includes a timeline with every journaled action and the hook's own counters (matched / slowed / suppressed).

A period starts when the change **took effect**, not when you made it. The script waits until no Claude process
from before the change is left, or until you confirm, and journals that moment as `effective`.

Then please **[share your numbers](https://github.com/omgapnt/claude-summary-tuner/issues/new?template=share-results.yml)**. Real baseline-vs-throttled data
from different workloads is the most useful thing this project can collect.

## Replicate the Flamerix test

`-Replicate` (menu 8) follows the protocol in the
[Tested versions section](https://gist.github.com/flamerix-ai/c3905705cc4205e5de3011fa2e74efce) of Flamerix's
write-up:

1. **Static check:** it hashes your `claude.exe` and checks that the hook's source anchors are still in the binary.
2. **Live A/B:** it runs `claude -p --model haiku` with `CLAUDE_CODE_AGENT_PROGRESS_SUMMARIES=1`. One subagent
   does 8 × `sleep 20`. The script counts `[AgentSummary]` forks in `--debug-file`. There are four arms: no hook,
   hook `pass`, hook `off`, and a `slow` arm (1 min by default). Telemetry is cross-checked through the logger.

Our result on **Windows, Claude Code 2.1.312** (29 Oct 2026):

| Summary forks in one short agent run (8 × `sleep 20`) | no hook | hook `pass` | hook `off` | hook `slow` (1 min) |
|---|:-:|:-:|:-:|:-:|
| **Flamerix**: Linux, 2.1.312, hook v2 | 5 | 5 | 0 | n/a |
| **This repo**: Windows, 2.1.312 | **5** | **5** | **0** | **2** |
| This repo: `agent_summary` requests seen in telemetry | 5 | 5 | 0 | 2 |

Total cost of the four runs: **$0.027** (Claude Code's estimate, Haiku). Flamerix's newer v3 hook row for
2.1.312 reads 5 / 6 / 0; they explain the extra fork as one more 30 s tick on a slow run. The binaries differ
(Windows `6099672ebe5d…` vs Linux `4f4178ce41d8…`), so this is an independent reproduction, not a copy.

<details>
<summary>Screenshot of the Replicate section of that report (paths anonymised)</summary>

<img src="docs/img/replicate-windows-2.1.312.png" alt="Replicate run: 5 / 5 / 0, slow 1 min: 2" width="760">

The raw result is in [`test/fixtures/replicate-windows-2.1.312.json`](test/fixtures/replicate-windows-2.1.312.json).
</details>

**What `pass` = `no hook` shows:** loading the hook on its own changes nothing. **What `off` = 0 shows:** the
hook is what removes the forks. **What `slow` = 2 shows:** in this one 3-minute run, a 1-minute minimum cut the
forks from 5 to 2. We have **not** yet measured how much slow mode saves over days of real use. That is what the
baseline → switch experiment is for.

## How it works

```mermaid
flowchart LR
    subgraph You["Your Windows user account"]
        PS["Claude-Summary-Tuner.ps1"] -- writes --> HOOK["%LOCALAPPDATA%\cc-summary-tuner\no-agent-summary.js"]
        PS -- sets user env --> ENV["BUN_OPTIONS=--preload …<br>CC_AGENT_SUMMARY_MODE=pass|slow|off"]
        PS -- journal --> J["actions.jsonl"]
    end
    ENV --> CC["claude.exe (Bun)"]
    HOOK -. preloaded .-> CC
    CC -- "summary timer?<br>pass: run · slow: delay · off: drop" --> T(("setTimeout /<br>setInterval"))
    CC -- "OTLP logs (http/json)" --> COL["Local logger<br>127.0.0.1 only"]
    COL --> EV["events-*.tsv"]
    J --> R["HTML report"]
    EV --> R
    HL["hook log"] --> R
    CC -. counters .-> HL
```

- **The hook** wraps the global `setTimeout`/`setInterval` (and `timers.*`). It identifies the summary timer
  callback by two source anchors, `[AgentSummary] Timer fired` and `agent_summary`. Verdicts are cached per
  function in a `WeakMap`, and every other timer passes through untouched. The Claude Code binary is
  **not modified**.
- **Windows gate:** the hook installs only when `Bun.main` is the compiled Claude Code entry. That is
  `/$bunfs/…` on Linux/macOS and `X:/~BUN/…` on Windows.
- **BUN_OPTIONS quirks:** Bun needs forward slashes and no spaces. Quoted paths are silently ignored. If your
  profile path contains a space, the script uses the 8.3 short path or a `%ProgramData%` folder, and it checks
  that the preload really loads before it saves anything.
- **The logger** is a small PowerShell `HttpListener` on a loopback port, with a `TcpListener` fallback. It autostarts hidden at logon via
  `HKCU\…\Run\ClaudeSummaryTunerCollector`, which shows up in Task Manager → Startup apps.

## ⚠ Restart everything after every change

Environment variables are read only when a process starts. After **each** mode change, close:

- **every** Claude Code session in every terminal tab and window, including VS Code and JetBrains terminals.
  Old terminal tabs keep the old environment, so **open new ones**;
- the **Claude Code daemon** and background sessions: `claude daemon stop --any`. This **ends running
  background sessions**, and the script offers to run it for you;
- the **Claude desktop app**: quit it from the tray icon, then reopen it.

Run `-CheckRestart` or `-Status` to see which Claude processes still run the old setting.

## Safety & privacy

- **No admin.** Everything is per-user: files in `%LOCALAPPDATA%\cc-summary-tuner\`, user env vars and one HKCU
  Run value.
- **Loopback only.** The logger binds to `127.0.0.1`, so nothing leaves your PC.
- **No prompt text.** Claude Code redacts prompts in telemetry by default, and this tool never turns prompt
  logging on. For each API request it stores only the time, event type, model, `query_source`, token counts,
  Claude Code's cost estimate, duration, Claude Code version, agent type and session id. It does **not** store
  e-mail, account or org IDs, prompts or responses.
- **Respects existing telemetry.** If you already export Claude Code telemetry somewhere, for example through a
  company setup, the script warns you and leaves those settings alone.
- **No downloads at runtime.** The hook and logger are embedded in the script, and the report loads nothing from
  the internet.
- **Before you share a report:** its header contains your PC name and data-folder path, which includes your
  Windows user name. Blur them first.

## Uninstall

```powershell
.\Claude-Summary-Tuner.ps1 -Uninstall              # asks whether to keep the data
.\Claude-Summary-Tuner.ps1 -Uninstall -DeleteData
```

Without the script: delete the user env vars `BUN_OPTIONS` (or only our `--preload …no-agent-summary.js` part of
it), `CC_AGENT_SUMMARY_MODE`, `CC_AGENT_SUMMARY_MIN_DELAY_MS` and `CC_AGENT_SUMMARY_LOG`. If you used the logger,
also delete the four `OTEL_*`/`CLAUDE_CODE_ENABLE_TELEMETRY` variables and the `ClaudeSummaryTunerCollector`
Run value. Then restart every Claude Code session.

If Claude is still running during uninstall, the hook file is replaced with an empty stub instead of deleted. A
missing preload file would stop Claude Code from starting.

## FAQ / troubleshooting

<details><summary><b>I switched modes but nothing changed.</b></summary>

Some Claude process was started before the change, most often an old terminal tab, the `claude daemon`, or the
desktop app. Run `-Status`: every process shows **Hook loaded** yes or no. Stop the daemon with
`claude daemon stop --any`.
</details>

<details><summary><b>I set BUN_OPTIONS by hand and the hook doesn't load.</b></summary>

Bun ignores a quoted path **silently**, and a path with spaces breaks it. Use forward slashes with no quotes,
e.g. `--preload C:/Users/you/AppData/Local/cc-summary-tuner/no-agent-summary.js`, or let the script set it.
</details>

<details><summary><b>Claude Code updated. Am I still protected?</b></summary>

Maybe not. The hook matches on source text, and an update can rename what it looks for. It **fails open**: the
summaries silently come back, and nothing breaks. After every update, run `-Replicate` (about $0.03) or watch the report's hook evidence table. A period in slow/off mode with zero matched timers means the
anchors no longer match.
</details>

<details><summary><b>Does the desktop app pick it up?</b></summary>

**Untested.** The desktop app's Code tab runs its own bundled Claude Code, and whether it inherits your user
environment is not documented. Quit and reopen the app, then check `-Status` for its process.
</details>

<details><summary><b>Is the cost in the report real money?</b></summary>

No. `cost_usd` is Claude Code's own estimate at API list prices. On Pro/Max subscriptions, read it as rate-limit
headroom you use up.
</details>

<details><summary><b>macOS / Linux?</b></summary>

Use [Flamerix's gist](https://gist.github.com/flamerix-ai/c3905705cc4205e5de3011fa2e74efce) directly. This
script is Windows-only. Only the unit tests run cross-platform.
</details>

## What's tested and what isn't

| | Status |
|---|---|
| Hook on Windows, Claude Code 2.1.312: no hook / pass / off / slow | ✅ Replicate run, 5 / 5 / 0 / 2 |
| Logger capturing `agent_summary` requests by `query_source` | ✅ Matched the debug-log fork counts in the same run |
| Unit tests: BUN_OPTIONS merge, number formatting under de-CH, periods, report | ✅ `pwsh test/unit.ps1`, 23/23 pass. A GitHub Actions workflow runs them on Linux |
| Script runs on Windows | ✅ The Replicate run above; parse-checked with PowerShell 7.4 |
| Full first-time install flow on a fresh machine | ⚠️ **not yet tested.** Please report |
| Desktop app's bundled CLI honouring `BUN_OPTIONS` | ⚠️ **not yet tested** |
| Savings from slow mode over days of real use | ⚠️ **not yet measured.** [Share yours](https://github.com/omgapnt/claude-summary-tuner/issues/new?template=share-results.yml) |

## Repo layout

```text
Claude-Summary-Tuner.ps1   the single-file download (built from src/, CRLF, ASCII)
src/                       hook.js, collector.ps1 and script parts; build.sh rebuilds the root script
test/unit.ps1              unit tests (pwsh, synthetic data)
test/fixtures/             sample report, our anonymised Windows replicate result
docs/img/                  screenshots
```

Changed something in `src/`? Run `bash src/build.sh`. `bash src/build.sh --check` verifies that the root script
matches.

## Credits

- **[Flamerix AI](https://flamerix.ai)** found and measured the `agent_summary` overhead and wrote the original
  Bun preload hook, [`no-agent-summary.js`](https://gist.github.com/flamerix-ai/c3905705cc4205e5de3011fa2e74efce)
  (MIT). Our `src/hook.js` is **derived from their v2 hook**, with a Windows `Bun.main` gate, `slow` mode and a
  slowed counter added. Their copyright notice is kept in the file. The Replicate mode follows their published
  test protocol. Thanks also to the contributors in the gist's comments, such as Bedz01.
- The idea of grouping `claude_code.api_request` telemetry by `query_source` also comes from Flamerix's write-up.

## Disclaimer

Unofficial, and **not affiliated with, sponsored or endorsed by Anthropic**. "Claude" and "Claude Code" are
trademarks of Anthropic, PBC. This tool changes how the Claude Code client behaves at runtime. The binary itself
is not modified. That may conflict with the terms of the service you use it with, and checking that is on you.
Provided **as is**, without warranty. See [LICENSE](LICENSE).
