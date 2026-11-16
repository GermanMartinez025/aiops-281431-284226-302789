import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { available, updateApplication, versioned } from '../update-app.mjs';
import { sample, monitor } from './availability.mjs';
import { parseEvidence } from './export-evidence.mjs';
import { createServer } from 'node:http';
import { mkdtemp, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const deployment = () => ({ metadata: { generation: 1, resourceVersion: '1' },
  spec: { replicas: 1, template: { metadata: { annotations: {} }, spec: { containers: [{ name: 'pharmago-ui', image: 'pharmago-ui:v1' }] } } },
  status: { observedGeneration: 1, updatedReplicas: 1, readyReplicas: 1, availableReplicas: 1, replicas: 1 } });
function harness({ badRollout = false, badProbe = false, badRollback = false, concurrent = false, baselineReady = true, baselineImage = 'pharmago-ui:v1' } = {}) {
  let live = deployment(), patches = 0, probes = 0;
  live.spec.template.spec.containers[0].image = baselineImage;
  if (!baselineReady) live.status.availableReplicas = 0;
  const deps = { log() {}, async probe() { if (++probes === 2 && badProbe) throw new Error('HTTP 500'); }, async k(args) {
    if (args[0] === 'get' && args[1] === 'deployment') return JSON.stringify(live);
    if (args[0] === 'get' && args[1] === 'endpointslices') return JSON.stringify({ items: [{ endpoints: [{ conditions: { ready: true } }] }] });
    if (args[0] === 'create') return JSON.stringify(deployment());
    if (args[0] === 'apply') return '';
    if (args[0] === 'patch') {
      const patch = JSON.parse(await readFile(args[args.indexOf('--patch-file') + 1], 'utf8'));
      assert.equal(patch[0].value, live.metadata.resourceVersion);
      live.spec = patch[1].value; patches++;
      return '';
    }
    if (args[0] === 'rollout') {
      if (patches === 1 && concurrent) live.spec.template.metadata.annotations['pharmago.io/update-id'] = 'other';
      if ((patches === 1 && badRollout) || (patches === 2 && badRollback)) throw new Error('Timeout');
      return '';
    }
    throw new Error(`Comando inesperado ${args}`);
  } };
  return { deps, get live() { return live; }, get patches() { return patches; } };
}
const options = { app: 'ui', image: 'pharmago-ui:v2', probeUrl: 'http://localhost/' };
test('entrypoint del observador funciona con symlink como en un ConfigMap', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'pharmago-symlink-test-'));
  try {
    const link = join(dir, 'observer.mjs');
    try { await symlink(fileURLToPath(new URL('./availability.mjs', import.meta.url)), link); }
    catch (e) { if (e.code === 'EPERM') { t.skip('Windows no permite crear symlinks; el montaje real se verifica en Kubernetes.'); return; } throw e; }
    const r = spawnSync(process.execPath, [link, '--targets', '[]'], { encoding: 'utf8' });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /Targets\/duracion/);
  } finally { await rm(dir, { recursive: true, force: true }); }
});
test('manifiestos reales: estrategia, probes, drenaje y selectores PDB consistentes', () => {
  const base = new URL('../', import.meta.url);
  const render = path => {
    const r = spawnSync(process.platform === 'win32' ? 'kubectl.exe' : 'kubectl',
      ['create', '--dry-run=client', '--validate=false', '-f', fileURLToPath(new URL(path, base)), '-o', 'json'], { encoding: 'utf8', windowsHide: true });
    assert.equal(r.status, 0, r.stderr);
    // kubectl create imprime un objeto JSON por documento YAML, no una List.
    const documents = r.stdout.trim().split(/\r?\n(?=\{)/).map(x => JSON.parse(x));
    return documents.length === 1 ? documents[0] : { items: documents };
  };
  const pdbs = render('pdb/application-pdb.yaml').items;
  const deployments = ['frontend/ui-deployment.yaml', 'backend/api-gateway-deployment.yaml', 'backend/users-service-deployment.yaml', 'backend/pharmacy-service-deployment.yaml'];
  for (const path of deployments) {
    const d = render(`deployments/${path}`), spec = d.spec, pod = spec.template.spec, c = pod.containers[0];
    assert.equal(spec.strategy.type, 'RollingUpdate');
    assert.deepEqual(spec.strategy.rollingUpdate, { maxSurge: 1, maxUnavailable: 0 });
    assert.equal(spec.minReadySeconds, 10);
    assert.equal(spec.progressDeadlineSeconds, 300);
    assert.equal(spec.replicas, path.includes('pharmacy') ? 2 : 1);
    assert.equal(pod.terminationGracePeriodSeconds, 30);
    assert.deepEqual(c.lifecycle.preStop.exec.command, ['/bin/sh', '-c', 'sleep 10']);
    assert.ok(c.readinessProbe.httpGet);
    const pdb = pdbs.find(p => p.spec.selector.matchLabels.app === spec.template.metadata.labels.app);
    assert.equal(pdb?.spec.minAvailable, 1);
    const servicePath = path.startsWith('frontend/') ? 'services/frontend/ui-service.yaml' : `services/backend/${path.split('/')[1].replace('-deployment.yaml', '-service.yaml')}`;
    const service = render(servicePath);
    assert.equal(service.spec.selector.app, spec.template.metadata.labels.app);
    assert.equal(service.spec.ports[0].targetPort, c.ports[0].containerPort);
  }
});
test('rechaza baseline no saludable o mutable sin modificar Deployment', async () => {
  for (const config of [{ baselineReady: false }, { baselineImage: 'pharmago-ui:latest' }]) {
    const h = harness(config);
    await assert.rejects(updateApplication(options, h.deps), /base completamente/);
    assert.equal(h.patches, 0);
  }
});
test('actualizacion valida cambia imagen y verifica estado', async () => {
  const h = harness();
  await updateApplication(options, h.deps);
  assert.equal(h.live.spec.template.spec.containers[0].image, options.image);
  assert.equal(h.patches, 1);
});
test('fallo de rollout o funcional restaura baseline y sale con error', async () => {
  for (const config of [{ badRollout: true }, { badProbe: true }]) {
    const h = harness(config);
    await assert.rejects(updateApplication(options, h.deps), /ROLLBACK VERIFICADO/);
    assert.equal(h.live.spec.template.spec.containers[0].image, 'pharmago-ui:v1');
    assert.equal(h.patches, 2);
  }
});
test('rollback fallido se informa y no se declara recuperacion', async () => {
  const h = harness({ badRollout: true, badRollback: true });
  await assert.rejects(updateApplication(options, h.deps), /ROLLBACK NO VERIFICADO/);
});
test('no pisa una actualizacion concurrente', async () => {
  const h = harness({ badRollout: true, concurrent: true });
  await assert.rejects(updateApplication(options, h.deps), /plantilla ajena/);
  assert.equal(h.patches, 1);
});
test('validacion de imagen y disponibilidad no acepta estado parcial', () => {
  assert.equal(versioned('registry:5000/ui'), false);
  assert.equal(versioned('registry:5000/ui:v1'), true);
  assert.equal(versioned('ui:latest'), false);
  const d = deployment(); d.status.readyReplicas = 0;
  assert.equal(available(d), false);
});
test('exportador rechaza logs incompletos y conserva errores observados', () => {
  assert.throws(() => parseEvidence('2026-11-15T00:00:00Z,test,200,true,1,\n'), /incompleta/);
  const row = '2026-11-15T00:00:00Z,test,503,false,1,\n';
  const summary = { counts: { test: { requests: 1, failures: 1 } }, failures: 1, passed: false };
  assert.equal(parseEvidence(row + JSON.stringify(summary)).summary.passed, false);
  summary.counts.test.requests = 2;
  assert.throws(() => parseEvidence(row + JSON.stringify(summary)), /incompleto/);
});
test('observador detecta contenido invalido, HTTP 500 y errores de conexion sin reintentar', async () => {
  for (const [status, body] of [[200, '{}'], [500, '[]']]) {
    let calls = 0;
    const r = await sample({ url: 'http://example.test', kind: 'json-array' }, async () => {
      calls++; return { status, text: async () => body };
    });
    assert.equal(r.ok, false); assert.equal(calls, 1);
  }
  assert.equal((await sample({ url: 'http://example.test' }, async () => { throw new Error(); })).ok, false);
});
test('observador HTTP real guarda evidencia y detecta fallo durante la ventana', async () => {
  let count = 0;
  const server = createServer((req, res) => { res.statusCode = ++count === 2 ? 503 : 200; res.end('[]'); });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const out = await mkdtemp(join(tmpdir(), 'pharmago-probe-test-'));
  try {
    const result = await monitor({ targets: [{ name: 'test', url: `http://127.0.0.1:${server.address().port}/`, kind: 'json-array' }], seconds: 1, interval: 100, out });
    assert.equal(result.passed, false);
    assert.equal(result.failures, 1);
    assert.match(await readFile(join(out, 'requests.csv'), 'utf8'), /503,false/);
  } finally { server.closeAllConnections(); await new Promise(r => server.close(r)); await rm(out, { recursive: true }); }
});
