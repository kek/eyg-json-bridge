// Copy runtime modules only: never ship compiler caches, absolute paths or tests.
import { readdir, readFile, copyFile, writeFile, mkdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
const generated = new URL('../build/dev/javascript/', import.meta.url).pathname;
const packages = new URL('../build/packages/', import.meta.url).pathname;
const dist = new URL('../dist/', import.meta.url).pathname;
await rm(dist, { recursive: true, force: true });
await mkdir(dist, { recursive: true });
async function copyModules(from, to) {
  for (const entry of await readdir(from, { withFileTypes: true })) {
    if (entry.name === '_gleam_artefacts') continue;
    const source = join(from, entry.name), destination = join(to, entry.name);
    if (entry.isDirectory()) {
      await mkdir(destination, { recursive: true });
      await copyModules(source, destination);
    } else if (entry.name.endsWith('.mjs') &&
      !/^(portability_test|worker\.test|gleam@@private_main)/.test(entry.name)) {
      await copyFile(source, destination);
    }
  }
}
// A renamed checkout may retain the previous project's generated directory.
// Copy only the current project and resolved dependencies, never stale projects.
const project = (await readFile(new URL('../gleam.toml', import.meta.url), 'utf8'))
  .match(/^name\s*=\s*"([^"]+)"/m)?.[1];
if (!project) throw new Error('Missing Gleam project name');
await copyFile(join(generated, 'prelude.mjs'), join(dist, 'prelude.mjs'));
const allowed = new Set([project, ...(await readdir(packages))]);
for (const entry of await readdir(generated, { withFileTypes: true })) {
  if (!entry.isDirectory() || !allowed.has(entry.name)) continue;
  const destination = join(dist, entry.name);
  await mkdir(destination, { recursive: true });
  await copyModules(join(generated, entry.name), destination);
}
const rows = [];
for (const entry of (await readdir(packages, { withFileTypes: true })).sort((a,b) => a.name.localeCompare(b.name))) {
  if (!entry.isDirectory()) continue;
  const dir = join(packages, entry.name);
  let manifest;
  try { manifest = await readFile(join(dir, 'gleam.toml'), 'utf8'); } catch { continue; }
  const version = manifest.match(/^version\s*=\s*"([^"]+)"/m)?.[1] ?? 'unknown';
  const licences = manifest.match(/^licen[cs]es\s*=\s*(\[[^\]]*\])/m)?.[1] ?? 'see source package';
  rows.push(`${entry.name} ${version}: ${licences}`);
  for (const file of await readdir(dir)) {
    if (!/^(licen[cs]e|copying|notice)(\.|$)/i.test(file)) continue;
    try { await copyFile(join(dir, file), join(dist, entry.name, file)); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
}
await writeFile(join(dist, 'DEPENDENCIES.txt'), rows.join('\n') + '\n');
