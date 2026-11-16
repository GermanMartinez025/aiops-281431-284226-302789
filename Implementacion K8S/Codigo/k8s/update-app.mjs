#!/usr/bin/env node
// Node >= 18, sin paquetes externos. Un componente por transaccion.
import { spawn } from 'node:child_process';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

const root = dirname(fileURLToPath(import.meta.url));
export const applications = {
  ui: ['pharmago-ui', 'frontend/ui-deployment.yaml'],
  gateway: ['pharmago-api-gateway', 'backend/api-gateway-deployment.yaml'],
  users: ['pharmago-users-service', 'backend/users-service-deployment.yaml'],
  pharmacy: ['pharmago-pharmacy-service', 'backend/pharmacy-service-deployment.yaml']
};
export function versioned(image) {
  if (/@sha256:[a-f0-9]{64}$/.test(image)) return true;
  const tag = image.slice(image.lastIndexOf('/') + 1).split(':')[1];
  return !!tag && !['latest', 'dev', 'stable'].includes(tag);
}
export function available(d) {
  const n = d.spec.replicas ?? 1;
  return d.status?.observedGeneration >= d.metadata.generation &&
    d.status?.updatedReplicas === n && d.status?.readyReplicas === n &&
    d.status?.availableReplicas === n && d.status?.replicas === n &&
    !d.status?.conditions?.some(c => c.type === 'Progressing' && c.status === 'False');
}
async function command(args, timeout = 30000) {
  return new Promise((accept, reject) => {
    const p = spawn(process.platform === 'win32' ? 'kubectl.exe' : 'kubectl', args,
      { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '', expired = false;
    p.stdout.on('data', x => { stdout += x; });
    p.stderr.on('data', x => { stderr += x; });
    const timer = setTimeout(() => { expired = true; p.kill(); }, timeout);
    p.on('error', e => { clearTimeout(timer); reject(e); });
    p.on('close', code => {
      clearTimeout(timer);
      if (code !== 0 || expired) reject(new Error(expired ? 'Timeout de kubectl' : stderr.trim() || `kubectl termino con ${code}`));
      else accept(stdout);
    });
  });
}
export async function httpProbe(url, expectedBody = '') {
  const r = await fetch(url, { redirect: 'manual', signal: AbortSignal.timeout(5000) });
  const body = await r.text();
  if (r.status !== 200 || (expectedBody && !body.includes(expectedBody)))
    throw new Error(`Prueba funcional: HTTP ${r.status} o contenido inesperado`);
}

export async function updateApplication(o, dependencies = {}) {
  const entry = applications[o.app];
  if (!entry || !o.image || !versioned(o.image)) throw new Error('Indique --app ui|gateway|users|pharmacy y --image con tag unico o digest; no latest.');
  const parsed = new URL(o.probeUrl);
  if (!['http:', 'https:'].includes(parsed.protocol)) throw new Error('--probe-url debe ser HTTP(S).');
  const [name, manifest] = entry;
  const context = o.context || 'minikube';
  const log = dependencies.log || console.log;
  const k = dependencies.k || ((args, timeout) => command(['--context', context, '-n', 'pharmago', ...args], timeout));
  const probe = dependencies.probe || (() => httpProbe(o.probeUrl, o.expectBody));
  const read = async () => JSON.parse(await k(['get', 'deployment', name, '-o', 'json', '--request-timeout=10s']));
  const previous = await read();
  const previousImage = previous.spec.template.spec.containers[0].image;
  if (!o.bootstrap && (!available(previous) || !versioned(previousImage)))
    throw new Error('Se requiere una base completamente disponible y con imagen versionada. Use --bootstrap solo para preparar/recuperar la base; no demuestra cero cortes.');
  if (previousImage === o.image) throw new Error('La imagen ya esta desplegada: use una version nueva, sin sobrescribir tags.');
  if (!o.bootstrap) await probe();
  else log('BOOTSTRAP: no se acredita continuidad ni rollback a una base saludable.');

  // El YAML del repositorio es la fuente de estrategia, probes y lifecycle.
  const desired = JSON.parse(await k(['create', '--dry-run=client', '--validate=false', '-f', join(root, 'deployments', manifest), '-o', 'json']));
  desired.spec.template.spec.containers[0].image = o.image;
  const id = randomUUID();
  desired.spec.template.metadata.annotations = { ...desired.spec.template.metadata.annotations, 'pharmago.io/update-id': id };
  const work = await mkdtemp(join(tmpdir(), 'pharmago-rollout-'));
  let changed = false;
  const patch = async (current, spec) => {
    const path = join(work, 'patch.json');
    await writeFile(path, JSON.stringify([
      { op: 'test', path: '/metadata/resourceVersion', value: current.metadata.resourceVersion },
      { op: 'replace', path: '/spec', value: spec }
    ]), { mode: 0o600 });
    await k(['patch', 'deployment', name, '--type=json', '--patch-file', path, '--request-timeout=15s']);
  };
  const check = async image => {
    const live = await read();
    if (!available(live) || live.spec.template.spec.containers[0].image !== image)
      throw new Error('Estado final incompleto o imagen inesperada.');
    const slices = JSON.parse(await k(['get', 'endpointslices', '-l', `kubernetes.io/service-name=${name}`, '-o', 'json', '--request-timeout=10s']));
    if (!slices.items.some(s => s.endpoints?.some(e => e.conditions?.ready === true)))
      throw new Error('El Service no tiene endpoints Ready.');
    await probe();
  };
  try {
    await k(['apply', '-f', join(root, 'pdb/application-pdb.yaml'), '--request-timeout=15s']);
    // Se marca antes: incluso un timeout de la peticion puede haber persistido el cambio.
    changed = true;
    await patch(previous, desired.spec);
    await k(['rollout', 'status', `deployment/${name}`, '--timeout=300s'], 315000);
    await check(o.image);
    log(`OK ${name}: version disponible y prueba funcional correcta.`);
    return { rolledBack: false };
  } catch (error) {
    if (!changed) throw error;
    let current;
    try { current = await read(); }
    catch (readError) { throw new Error(`ROLLBACK NO VERIFICADO: no se pudo consultar el Deployment: ${readError.message}; fallo original: ${error.message}`); }
    if (current.spec.template.metadata.annotations?.['pharmago.io/update-id'] !== id)
      throw new Error(`Actualizacion fallida; no se revierte una plantilla ajena o un cambio no aplicado: ${error.message}`);
    log(`Fallo: ${error.message}. Recuperando la especificacion anterior...`);
    try {
      // Restaura imagen, plantilla, estrategia y replicas; no toca SQL/PV/PVC/Services.
      await patch(current, previous.spec);
      await k(['rollout', 'status', `deployment/${name}`, '--timeout=300s'], 315000);
      await check(previousImage);
    } catch (rollbackError) {
      throw new Error(`ROLLBACK NO VERIFICADO: ${rollbackError.message}; fallo original: ${error.message}`);
    }
    throw new Error(`Actualizacion fallida; ROLLBACK VERIFICADO a ${previousImage}. ${error.message}`);
  } finally {
    await rm(work, { recursive: true, force: true });
  }
}

export function parseOptions(args) {
  const allowed = { '--app': 'app', '--image': 'image', '--context': 'context', '--probe-url': 'probeUrl', '--expect-body': 'expectBody' };
  const o = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--bootstrap') { o.bootstrap = true; continue; }
    const key = allowed[args[i]];
    if (!key || !args[i + 1] || args[i + 1].startsWith('--')) throw new Error(`Argumento invalido: ${args[i]}`);
    o[key] = args[++i];
  }
  return o;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { await updateApplication(parseOptions(process.argv.slice(2))); }
  catch (e) { console.error(e.message); process.exitCode = 1; }
}
