#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = dirname(fileURLToPath(import.meta.url));
const code = dirname(root);
let tag, profile = 'minikube', app;
for (let i = 2; i < process.argv.length; i += 2) {
  const key = process.argv[i], value = process.argv[i + 1];
  if (!value || !['--tag', '--profile', '--app'].includes(key)) throw new Error('Uso: node build-images.mjs --tag v1 [--profile minikube] [--app ui|gateway|users|pharmacy]');
  if (key === '--tag') tag = value;
  if (key === '--profile') profile = value;
  if (key === '--app') app = value;
}
const names = { ui: 'pharmago-ui', gateway: 'pharmago-api-gateway', users: 'pharmago-users-service', pharmacy: 'pharmago-pharmacy-service' };
const projects = { gateway: 'PharmaGo.ApiGateway', users: 'PharmaGo.UsersService', pharmacy: 'PharmaGo.PharmacyService' };
function run(tool, args, capture = false) {
  const r = spawnSync(process.platform === 'win32' ? `${tool}.exe` : tool, args,
    { windowsHide: true, stdio: capture ? 'pipe' : 'inherit', encoding: 'utf8' });
  if (r.error || r.status !== 0) throw new Error(`${tool} fallo: ${r.error?.message || r.stderr || r.status}`);
  return r.stdout;
}
try {
  if (!tag || !/^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$/.test(tag) || ['latest', 'dev', 'stable'].includes(tag) || (app && !names[app]))
    throw new Error('Se requiere --tag unico, distinto de latest/dev/stable, y una aplicacion valida.');
  run('docker', ['info'], true);
  run('kubectl', ['--context', profile, 'get', 'nodes', '--request-timeout=10s'], true);
  const selected = app ? [app] : Object.keys(names);
  const cached = run('minikube', ['--profile', profile, 'image', 'ls'], true);
  // Nunca sobrescribir la imagen que puede necesitar el rollback.
  for (const key of selected) {
    const image = `${names[key]}:${tag}`;
    const found = spawnSync(process.platform === 'win32' ? 'docker.exe' : 'docker', ['image', 'inspect', image], { windowsHide: true, stdio: 'ignore' });
    if (found.error) throw found.error;
    if (found.status === 0 || cached.split(/\s+/).some(x => x === image || x.endsWith(`/${image}`))) throw new Error(`El tag ${image} ya existe. Use otro tag.`);
  }
  for (const key of selected) {
    const image = `${names[key]}:${tag}`;
    const folder = key === 'ui' ? join(code, 'Frontend') : join(code, 'Backend');
    const dockerfile = key === 'ui' ? join(folder, 'Dockerfile') : join(folder, projects[key], 'Dockerfile');
    run('docker', ['build', '-f', dockerfile, '-t', image, '--label', `org.opencontainers.image.version=${tag}`, folder]);
    run('minikube', ['--profile', profile, 'image', 'load', image]);
    console.log(`CARGADA ${image}; ningun Deployment fue modificado.`);
  }
} catch (e) { console.error(e.message); process.exitCode = 1; }
