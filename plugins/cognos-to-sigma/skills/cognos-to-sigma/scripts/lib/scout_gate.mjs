// Shared "run-each-time gap-scout gate" (bead beads-sigma-5l5e) — Node side.
//
// Mirrors scout_gate.rb / scout_gate.py EXACTLY: a per-conversion JSONL ledger at
// <workdir>/scout-ledger.jsonl, one row per scouted gap:
//   { "gap_id": ..., "feature": ..., "status": "validated"|"escalated", "at": ... }
//
// The orchestrator (migrate-cognos.mjs) maps its own gap representation to a list
// of stable gap-id strings and calls classify(); the scout
// (scout-validate-and-persist.mjs) appends to the ledger via record(). The JSONL
// format is the language-neutral contract — a Ruby/Python/Node scout all write
// rows the others can read. Kept dependency-free so it can be vendored unchanged.
import { existsSync, statSync, readFileSync, appendFileSync } from 'node:fs';
import { join } from 'node:path';

const LEDGER = 'scout-ledger.jsonl';

export function ledgerPath(workdir) {
  return join(String(workdir || ''), LEDGER);
}

// Append one scout result. Non-fatal on error — a failed ledger write must never
// crash a scout that otherwise succeeded.
export function record(workdir, { gapId, feature, status }) {
  try {
    if (!workdir || !existsSync(workdir) || !statSync(workdir).isDirectory()) return false;
    const row = {
      gap_id: String(gapId || feature),
      feature: String(feature),
      status: String(status),
      at: new Date().toISOString(),
    };
    appendFileSync(ledgerPath(workdir), JSON.stringify(row) + '\n');
    return true;
  } catch (e) {
    console.error(`scout-ledger write failed (non-fatal): ${e.message}`);
    return false;
  }
}

export function readLedger(workdir) {
  const p = ledgerPath(workdir);
  if (!existsSync(p)) return [];
  const out = [];
  for (const line of readFileSync(p, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t) continue;
    try { out.push(JSON.parse(t)); } catch { /* skip malformed */ }
  }
  return out;
}

// gapIds: string[] — the unhandled gaps the scout was supposed to cover.
// Returns three disjoint buckets of gap-ids (mirrors scout_gate.rb#classify):
//   unscouted — no ledger row at all (scout never ran) → hard STOP
//   escalated — scouted, every row is 'escalated' (tried, unsolved) → needs --yes/--force
//   validated — has at least one 'validated' row (solved locally)
export function classify(workdir, gapIds) {
  const by = {};
  for (const e of readLedger(workdir)) {
    const k = String(e.gap_id);
    (by[k] = by[k] || []).push(e);
  }
  const unscouted = gapIds.filter((id) => !by[String(id)]);
  const rest = gapIds.filter((id) => by[String(id)]);
  const validated = rest.filter((id) => by[String(id)].some((x) => x.status === 'validated'));
  const escalated = rest.filter((id) => !validated.includes(id));
  return { unscouted, escalated, validated };
}
