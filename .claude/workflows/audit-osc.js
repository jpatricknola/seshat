export const meta = {
  name: 'audit-osc',
  description: 'Verify every OSC address in the codebase against the canonical AbletonOSC API docs',
  whenToUse: 'After upgrading AbletonOSC, after a batch of new tools, or when a tool silently does nothing',
  phases: [
    { title: 'Extract', detail: 'collect every /live/ address used in lib/' },
    { title: 'Verify', detail: 'check each batch against docs/abletonosc-api-docs.md' },
  ],
}

// Wrong addresses fail silently (UDP, no reply), and AbletonOSC's naming is
// irregular — so every address literal gets checked against the canonical
// reference, not against patterns.

phase('Extract')

const SITES_SCHEMA = {
  type: 'object',
  required: ['sites'],
  properties: {
    sites: {
      type: 'array',
      items: {
        type: 'object',
        required: ['file', 'line', 'address', 'args'],
        properties: {
          file: { type: 'string', description: 'repo-relative path' },
          line: { type: 'integer' },
          address: { type: 'string', description: 'the /live/... address literal' },
          args: { type: 'string', description: 'the arguments passed at this call site, as written in the code' },
        },
      },
    },
  },
}

const extracted = await agent(
  `In this Elixir repo, find every OSC address literal (strings starting with "/live/") used in lib/.
Known files: lib/seshat/tools/handlers.ex, lib/seshat/commands/registry.ex, lib/seshat/session/state.ex, lib/seshat/library/catalog.ex — but grep all of lib/ in case there are others.
For each call site return the file, line number, the address string, and the arguments passed with it (transcribe the actual code expression, e.g. "[track_id, value]").
Skip test files and docs. Include every occurrence, even repeats of the same address — argument mistakes are per-site.`,
  { label: 'extract-addresses', schema: SITES_SCHEMA },
)

const sites = extracted?.sites ?? []
log(`${sites.length} OSC call sites found`)
if (sites.length === 0) return { error: 'extraction returned no sites — check lib/ manually' }

phase('Verify')

const VERDICTS_SCHEMA = {
  type: 'object',
  required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['file', 'line', 'address', 'problem', 'severity'],
        properties: {
          file: { type: 'string' },
          line: { type: 'integer' },
          address: { type: 'string' },
          problem: { type: 'string', description: 'what is wrong: unknown address, wrong arg count/order/type, deprecated form' },
          severity: { type: 'string', enum: ['broken', 'suspect'] },
          fix: { type: 'string', description: 'the correct address or argument shape per the docs' },
        },
      },
    },
  },
}

const BATCH = 8
const batches = []
for (let i = 0; i < sites.length; i += BATCH) batches.push(sites.slice(i, i + BATCH))

const results = await parallel(
  batches.map((batch, i) => () =>
    agent(
      `Audit these OSC call sites from the Seshat codebase against the canonical API reference.

Canonical sources:
- docs/abletonosc-api-docs.md — the authoritative address list with argument signatures. An address absent from this file does not exist upstream.
- priv/AbletonOSC/abletonosc/browser.py — the ONLY authority for /live/browser/* addresses (they are vendored, not upstream). Check the handler registrations in this file for those.
- .claude/docs/ableton-osc-reference.md — conventions and gotchas (ordering hazards, listener pattern).

For each site below, open the referenced file at the given line to see the real code in context, then verify:
1. the address exists in the canonical source;
2. the argument count, order, and types match the documented signature;
3. any documented ordering hazard or gotcha is respected.

Report ONLY problems (empty findings array if all sites check out). Severity "broken" = will silently do nothing or hit the wrong target; "suspect" = ambiguous vs the docs, needs a human look.

Sites:
${JSON.stringify(batch, null, 2)}`,
      { label: `verify-batch-${i + 1}`, phase: 'Verify', schema: VERDICTS_SCHEMA },
    ),
  ),
)

const findings = results.filter(Boolean).flatMap((r) => r.findings)
log(`${findings.length} problems across ${sites.length} sites`)

return {
  sitesAudited: sites.length,
  broken: findings.filter((f) => f.severity === 'broken'),
  suspect: findings.filter((f) => f.severity === 'suspect'),
}
