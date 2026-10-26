/**
 * Checks xGEO Core's physics against independent references (tools/verify;
 * docs/PHYSICS-VERIFICATION.md): Godot evaluates Core's own functions on a
 * grid of cases and writes the numbers out, then pytest compares them with
 * hapsira, scipy, astropy, filterpy, JPL Horizons data and published examples.
 *
 *   node tools/verify.mjs              the whole suite; the table goes to tools/verify/out/results.md
 *   node tools/verify.mjs -k moons     extra arguments go to pytest
 *
 * Needs Godot 4.7 (GODOT, else the winget install, else "godot" on the PATH)
 * and Python 3.12 or later. The first run makes tools/verify/.venv from
 * requirements.txt; after that it works offline (JPL data is in fixtures/).
 */
import { spawnSync, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const proj = path.join(root, 'godot');
const vdir = path.join(root, 'tools/verify');
const win = process.platform === 'win32';

const winget = path.join(os.homedir(), 'AppData/Local/Microsoft/WinGet/Packages');
const godot = process.env.GODOT ?? ((fs.existsSync(winget)
  && fs.readdirSync(winget).filter(d => d.startsWith('GodotEngine.GodotEngine')).map(d => path.join(winget, d))
    .flatMap(d => fs.readdirSync(d).filter(f => /_console\.exe$/.test(f)).map(f => path.join(d, f)))[0]) || 'godot');

const py = path.join(vdir, '.venv', win ? 'Scripts/python.exe' : 'bin/python');
if (!fs.existsSync(py)) {
  // A real Python 3.12+: the py launcher on Windows (the bare "python" there may be the Store stub).
  const cands = win ? [['py', ['-3.12']], ['py', ['-3']], ['python', []]] : [['python3.12', []], ['python3', []]];
  const found = cands.find(([c, a]) => spawnSync(c, [...a, '-c', 'import sys; assert sys.version_info >= (3, 12)'], { encoding: 'utf8' }).status === 0);
  if (!found) { console.error('verify: needs Python 3.12+ (e.g. winget install -e --id Python.Python.3.12)'); process.exit(2); }
  console.log('verify: creating tools/verify/.venv and installing tools/verify/requirements.txt');
  execFileSync(found[0], [...found[1], '-m', 'venv', path.join(vdir, '.venv')], { stdio: 'inherit' });
  execFileSync(py, ['-m', 'pip', 'install', '-q', '-r', path.join(vdir, 'requirements.txt')], { stdio: 'inherit' });
}
const env = { ...process.env, PYTHONUTF8: '1', PYTHONDONTWRITEBYTECODE: '1' };
if (!fs.existsSync(path.join(vdir, 'fixtures/horizons_moons.json'))) execFileSync(py, [path.join(vdir, 'fetch_fixtures.py')], { stdio: 'inherit', env });
execFileSync(py, [path.join(vdir, 'make_cases.py')], { stdio: 'inherit', env });

// Godot needs the project imported once (class names) before a script can run.
if (!fs.existsSync(path.join(proj, '.godot'))) spawnSync(godot, ['--headless', '--path', proj, '--import'], { encoding: 'utf8', timeout: 600000 });
const out = path.join(vdir, 'out/game_physics.json');
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.rmSync(out, { force: true });
const d = spawnSync(godot, ['--headless', '--path', proj, '--script', 'res://tests/dump_physics.gd', '--', `--cases=${path.join(vdir, 'fixtures/cases.json')}`, `--out=${out}`], { cwd: root, encoding: 'utf8', timeout: 600000 });
if (d.error) { console.error(`verify: could not run Godot (${godot}): ${d.error.message}. Set GODOT to the Godot 4.7 executable.`); process.exit(2); }
console.log((d.stdout + d.stderr).split('\n').filter(l => /dump_physics|SCRIPT ERROR|Parse Error/.test(l)).join('\n'));
if (!fs.existsSync(out)) { console.error('verify: Godot did not write the physics dump'); process.exit(1); }
const r = spawnSync(py, ['-m', 'pytest', '-c', path.join(vdir, 'pytest.ini'), '--rootdir', vdir, path.join(vdir, 'tests'), ...process.argv.slice(2)], { cwd: root, stdio: 'inherit', env });
console.log('verify: table in tools/verify/out/results.md');
process.exit(r.status ?? 1);
