#!/usr/bin/env node
// GET sin reintentos. Puede ejecutarse localmente o como pod observador.
import { mkdir, writeFile } from 'node:fs/promises';
import { realpathSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export async function sample(target, request = fetch) {
  const start = performance.now();
  try {
    const response = await request(target.url, { redirect: 'manual', signal: AbortSignal.timeout(5000) });
    const body = await response.text();
    let valid = response.status === 200;
    if (target.kind === 'json-array') {
      try { valid &&= Array.isArray(JSON.parse(body)); } catch { valid = false; }
    }
    if (target.contains) valid &&= body.includes(target.contains);
    return { status: response.status, ok: valid, ms: Math.round(performance.now() - start), error: '' };
  } catch (e) {
    return { status: 0, ok: false, ms: Math.round(performance.now() - start), error: e.name };
  }
}
export async function monitor({ targets, seconds = 420, interval = 2500, out = 'artifacts/rolling-update' }) {
  if (!Array.isArray(targets) || !targets.length || !Number.isFinite(seconds) || seconds < 1 ||
      !Number.isFinite(interval) || interval < 100) throw new Error('Targets/duracion/intervalo invalidos.');
  for (const t of targets) {
    if (!/^[a-zA-Z0-9_-]+$/.test(t.name) || !['http:', 'https:'].includes(new URL(t.url).protocol))
      throw new Error('Nombre o URL de target invalido.');
  }
  await mkdir(out, { recursive: true });
  await writeFile(resolve(out, 'started'), new Date().toISOString());
  const started = new Date().toISOString();
  const end = performance.now() + seconds * 1000;
  const rows = ['utc,target,status,ok,ms,error'];
  const counts = Object.fromEntries(targets.map(t => [t.name, { requests: 0, failures: 0 }]));
  const observe = async () => {
    await Promise.all(targets.map(async t => {
      const r = await sample(t);
      counts[t.name].requests++;
      if (!r.ok) counts[t.name].failures++;
      const row = `${new Date().toISOString()},${t.name},${r.status},${r.ok},${r.ms},${r.error}`;
      rows.push(row);
      console.log(row);
    }));
  };
  while (performance.now() < end) {
    const next = performance.now() + interval;
    await observe();
    await new Promise(r => setTimeout(r, Math.max(0, Math.min(next, end) - performance.now())));
  }
  const failures = Object.values(counts).reduce((n, c) => n + c.failures, 0);
  const summary = { started, ended: new Date().toISOString(), intervalMs: interval,
    targets, counts, failures, passed: failures === 0,
    scope: 'Cero errores observados en las solicitudes registradas; no demuestra disponibilidad absoluta ni intervalos no muestreados.' };
  await writeFile(resolve(out, 'requests.csv'), rows.join('\n') + '\n');
  await writeFile(resolve(out, 'summary.json'), JSON.stringify(summary, null, 2));
  console.log(JSON.stringify(summary));
  return summary;
}
// ConfigMap monta el archivo mediante symlinks: Node resuelve import.meta.url.
if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  try {
    const args = process.argv.slice(2), o = {};
    for (let i = 0; i < args.length; i += 2) {
      if (!['--targets', '--seconds', '--interval', '--out'].includes(args[i]) || !args[i + 1]) throw new Error('Argumento invalido.');
      o[args[i].slice(2)] = args[i + 1];
    }
    const result = await monitor({ targets: JSON.parse(o.targets || process.env.TARGETS_JSON || '[]'),
      seconds: Number(o.seconds || process.env.DURATION_SECONDS || 420),
      interval: Number(o.interval || 2500), out: o.out || '/tmp/rolling-update' });
    process.exitCode = result.passed ? 0 : 1;
  } catch (e) { console.error(e.message); process.exitCode = 1; }
}
