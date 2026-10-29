// no-agent-summary.js v2 + Windows gate + "slow" mode + slowed counter (patched for Claude-Summary-Tuner, 2026-10-29).
// Bun --preload hook that switches off (or slows) Claude Code's `agent_summary`
// side-query. Unofficial, not affiliated with Anthropic. Tested on Linux, Claude Code 2.1.301.
// Install, env vars, verification and fail-open caveats: README.md.
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Flamerix AI (https://flamerix.ai). Provided "as is", without warranty;
// full license text: README.md.
//
// Anchors: the summarizer's debug-log line and its query-source id, both inside the timer
// callback on 2.1.301.
const IN_COMPILED_BUN =
  typeof Bun !== "undefined" && typeof Bun.main === "string" && (Bun.main.startsWith("/$bunfs/") || /^[A-Za-z]:[\\/]~BUN[\\/]/.test(Bun.main));

function install() {
  const fs = require("fs");
  const ANCHORS = ["[AgentSummary] Timer fired", "agent_summary"];
  const RAW_MODE = process.env.CC_AGENT_SUMMARY_MODE || "off";
  const MODE = ["pass", "slow"].includes(RAW_MODE) ? RAW_MODE : "off";
  // slow: keep the per-agent status line, but stretch each summary timer to at least this many ms
  // (default 5 min). Fewer full-transcript re-reads; the status just updates less often.
  const MIN_DELAY = Math.max(30000, Number(process.env.CC_AGENT_SUMMARY_MIN_DELAY_MS) || 300000);
  if (RAW_MODE !== MODE) process.stderr.write(`[no-agent-summary] unknown mode ${RAW_MODE}, forcing off\n`);
  const LOG = process.env.CC_AGENT_SUMMARY_LOG;
  const log = (s) => { if (LOG) { try { fs.appendFileSync(LOG, `${new Date().toISOString()} pid=${process.pid} ${s}\n`); } catch {} } };

  const verdict = new WeakMap(); // fn -> bool (is the summary timer callback)
  function isSummaryTimer(fn) {
    if (typeof fn !== "function") return false;
    let v = verdict.get(fn);
    if (v === undefined) {
      try {
        const src = Function.prototype.toString.call(fn);
        v = ANCHORS.some((a) => src.includes(a));
      } catch { v = false; }
      verdict.set(fn, v);
    }
    return v;
  }

  let matched = 0;
  let suppressed = 0;
  let slowed = 0;
  const PROMISIFY = Symbol.for("nodejs.util.promisify.custom");
  const wrappers = new Map(); // original timer fn -> its wrapper: one wrapper per original
  const hookedFns = new WeakSet();
  function wrap(orig, name) {
    if (typeof orig !== "function") return orig;
    if (wrappers.has(orig)) return wrappers.get(orig);
    const hooked = function (fn, delay, ...args) {
      if (isSummaryTimer(fn)) {
        matched++;
        if (MODE === "off") {
          suppressed++;
          if (matched <= 20) log(`summary timer #${matched} suppressed (${name}, delay=${delay})`);
          const t = orig(() => {}, 2 ** 31 - 1); // clear*-compatible handle of the same kind, never fires
          if (t && typeof t.unref === "function") t.unref();
          return t;
        }
        if (MODE === "slow") {
          const d = Math.max(Number(delay) || 0, MIN_DELAY);
          slowed++;
          if (matched <= 20) log(`summary timer #${matched} slowed (${name}, delay=${delay} -> ${d})`);
          return orig(fn, d, ...args);
        }
        if (matched <= 20) log(`summary timer #${matched} passed (control, ${name}, delay=${delay})`);
      }
      return orig(fn, delay, ...args);
    };
    Object.defineProperty(hooked, "name", { value: name });
    // util.promisify(setTimeout) reads these; without the custom one it calls the wrapper
    // callback-last and node throws ERR_INVALID_ARG_TYPE.
    if (orig.__promisify__) hooked.__promisify__ = orig.__promisify__;
    if (orig[PROMISIFY]) hooked[PROMISIFY] = orig[PROMISIFY];
    wrappers.set(orig, hooked);
    hookedFns.add(hooked);
    return hooked;
  }

  // require("timers/promises").setTimeout(delay, value) takes no callback, so there is no source
  // to match an anchor in; it stays unwrapped.
  const timers = (() => { try { return require("timers"); } catch { return null; } })();
  const hookedApis = [];
  for (const name of ["setTimeout", "setInterval"]) {
    globalThis[name] = wrap(globalThis[name], name);
    if (hookedFns.has(globalThis[name])) hookedApis.push(`global.${name}`);
    if (timers) {
      try { timers[name] = wrap(timers[name], name); } catch {}
      if (hookedFns.has(timers[name])) hookedApis.push(`timers.${name}`);
    }
  }

  const active = `preload active mode=${MODE}${MODE === "slow" ? " min_delay=" + MIN_DELAY : ""} bun=${Bun.version} hooked=${hookedApis.join(",")}`;
  log(active);
  if (LOG) process.on("exit", () => log(`exit: ${suppressed} summary timer(s) suppressed, ${slowed} slowed, ${matched} matched`));
  const MARKER = process.env.CC_AGENT_SUMMARY_MARKER;
  if (MARKER) {
    try { fs.writeFileSync(MARKER, `${active} pid=${process.pid}\n`); }
    catch (e) { process.stderr.write(`[no-agent-summary] cannot write marker ${MARKER}: ${e.message}\n`); }
  }
}

if (IN_COMPILED_BUN) install();
