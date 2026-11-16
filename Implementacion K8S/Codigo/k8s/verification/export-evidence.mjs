#!/usr/bin/env node
// Lee kubectl logs por stdin: funciona tambien con pods ya terminados, sin exec/cp.
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export function parseEvidence(logs) {
  const lines = logs.split(/\r?\n/).filter(Boolean);
  const last = lines.filter(x => x.startsWith('{')).at(-1);
  if (!last) throw new Error('Observacion incompleta: falta el resumen final. Conservar logs y esperar.');
  const summary = JSON.parse(last);
  const rows = lines.filter(x => /^\d{4}-\d{2}-\d{2}T/.test(x));
  const counted = {};
  for (const row of rows) {
    const [utc, target, status, ok, ms, error, extra] = row.split(',');
    if (extra !== undefined || !Number.isFinite(Date.parse(utc)) || !/^\d+$/.test(status) ||
        !/^\d+$/.test(ms) || !['true','false'].includes(ok) || error === undefined)
      throw new Error('Fila CSV invalida.');
    counted[target] ??= { requests: 0, failures: 0 };
    counted[target].requests++;
    if (ok === 'false') counted[target].failures++;
  }
  if (!summary.counts || Object.keys(counted).length !== Object.keys(summary.counts).length)
    throw new Error('Los logs y el resumen no contienen los mismos targets.');
  for (const [target, c] of Object.entries(summary.counts)) {
    if (!c.requests || c.requests !== counted[target]?.requests || c.failures !== counted[target]?.failures)
      throw new Error('Registro incompleto: conteos de logs y resumen diferentes.');
  }
  const failures = Object.values(counted).reduce((n, x) => n + x.failures, 0);
  if (summary.failures !== failures || summary.passed !== (failures === 0)) throw new Error('Resultado inconsistente.');
  return { summary, csv: 'utc,target,status,ok,ms,error\n' + rows.join('\n') + '\n' };
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.length !== 4 || process.argv[2] !== '--out') throw new Error('Uso: kubectl logs ... | node export-evidence.mjs --out artifacts/ensayo');
    const logs = readFileSync(0, 'utf8'), evidence = parseEvidence(logs), out = resolve(process.argv[3]);
    mkdirSync(dirname(out), { recursive: true });
    mkdirSync(out); // No sobrescribir evidencias de una ejecucion anterior.
    writeFileSync(join(out, 'observer.log'), logs);
    writeFileSync(join(out, 'requests.csv'), evidence.csv);
    writeFileSync(join(out, 'summary.json'), JSON.stringify(evidence.summary, null, 2));
    console.log(JSON.stringify({ out, passed: evidence.summary.passed, counts: evidence.summary.counts }));
    process.exitCode = evidence.summary.passed ? 0 : 1;
  } catch (e) { console.error(e.message); process.exitCode = 1; }
}
