#!/usr/bin/env node
// Instalacion inicial exclusivamente. Las actualizaciones usan update-app.mjs.
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
const root = dirname(fileURLToPath(import.meta.url));
let tag, context = 'minikube';
for (let i = 2; i < process.argv.length; i += 2) {
  const [key, value] = process.argv.slice(i, i + 2);
  if (!value || !['--tag', '--context'].includes(key)) throw new Error('Uso: apply-k8s --tag v1 [--context minikube]');
  if (key === '--tag') tag = value;
  else context = value;
}
function k(args) {
  const r = spawnSync(process.platform === 'win32' ? 'kubectl.exe' : 'kubectl', ['--context', context, ...args],
    { windowsHide: true, encoding: 'utf8' });
  if (r.error || r.status !== 0) throw new Error(r.error?.message || r.stderr || `kubectl: ${r.status}`);
  return r.stdout;
}
let work;
try {
  if (!tag || !/^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$/.test(tag) || ['latest','dev','stable'].includes(tag)) throw new Error('Indique --tag unico de imagenes ya cargadas.');
  if (k(['get', 'namespace', 'pharmago', '--ignore-not-found', '-o', 'name', '--request-timeout=10s']).trim())
    throw new Error('pharmago ya existe: use update-app. No se reinstala ni se tocan sus volumenes.');
  const volumes = k(['get', 'pv', 'sql-pv', 'elasticsearch-pv', 'prometheus-pv', 'grafana-pv', '--ignore-not-found', '-o', 'name', '--request-timeout=10s']);
  if (volumes.trim()) throw new Error('Existen PV previos: requiere recuperacion/migracion explicita, no reinstalacion automatica.');
  const nodes = JSON.parse(k(['get', 'nodes', '-o', 'json', '--request-timeout=10s']));
  if (nodes.items.length !== 1) throw new Error('Este instalador local requiere un solo nodo.');
  k(['label', 'node', nodes.items[0].metadata.name, 'node-type=all', '--overwrite']);
  const apply = path => { k(['apply', '-f', join(root, path), '--request-timeout=15s']); console.log(`Aplicado ${path}`); };
  apply('namespace.yaml'); apply('secrets'); apply('configmaps'); apply('persistent-volumes');
  apply('services/backend'); apply('services/frontend'); apply('services/ops');
  apply('deployments/ops');
  k(['-n', 'pharmago', 'rollout', 'status', 'deployment/pharmago-db', '--timeout=300s']);
  work = mkdtempSync(join(tmpdir(), 'pharmago-install-'));
  const render = (name, file) => {
    const d = JSON.parse(k(['create', '--dry-run=client', '--validate=false', '-f', join(root, 'deployments', file), '-o', 'json']));
    d.spec.template.spec.containers[0].image = `${name}:${tag}`;
    return d;
  };
  const users = render('pharmago-users-service', 'backend/users-service-deployment.yaml');
  const migrationSpec = structuredClone(users.spec.template.spec);
  migrationSpec.restartPolicy = 'Never';
  const c = migrationSpec.containers[0];
  c.command = ['dotnet', 'PharmaGo.UsersService.dll', '--migrate-database'];
  delete c.readinessProbe; delete c.startupProbe; delete c.livenessProbe; delete c.lifecycle;
  const job = { apiVersion: 'batch/v1', kind: 'Job', metadata: { name: 'pharmago-schema-initial', namespace: 'pharmago' },
    spec: { backoffLimit: 0, activeDeadlineSeconds: 300, template: { spec: migrationSpec } } };
  const file = join(work, 'resource.json');
  writeFileSync(file, JSON.stringify(job), { mode: 0o600 });
  k(['apply', '-f', file]);
  k(['-n', 'pharmago', 'wait', '--for=condition=complete', 'job/pharmago-schema-initial', '--timeout=300s']);
  for (const [name, path] of [
    ['pharmago-users-service','backend/users-service-deployment.yaml'],
    ['pharmago-pharmacy-service','backend/pharmacy-service-deployment.yaml'],
    ['pharmago-api-gateway','backend/api-gateway-deployment.yaml'],
    ['pharmago-ui','frontend/ui-deployment.yaml']]) {
    writeFileSync(file, JSON.stringify(render(name, path)), { mode: 0o600 });
    k(['apply', '-f', file]);
    k(['-n', 'pharmago', 'rollout', 'status', `deployment/${name}`, '--timeout=300s']);
  }
  apply('pdb');
  console.log('Aplicaciones disponibles. Ejecute tambien las pruebas funcionales documentadas.');
} catch (e) { console.error(`Instalacion detenida: ${e.message}. No se elimina ningun recurso automaticamente.`); process.exitCode = 1; }
finally { if (work) rmSync(work, { recursive: true, force: true }); }
