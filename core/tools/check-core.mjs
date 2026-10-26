/**
 * xGEO Core must run without xGEO Live: nothing in godot/core/ or godot/cli/
 * may reach into the game's interface (godot/ui/, godot/scenes/) or name one
 * of its classes. Comments are skipped, so a note like "as the HUD shows" is fine.
 *
 *   node tools/check-core.mjs      exit 1 and list each line that breaks it
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dirs = ['godot/core', 'godot/cli'];

// Live's classes: every class_name declared under ui/ and scenes/ (none in
// the published Core, where the paths below are still checked).
const live = new Set();
for (const d of ['godot/ui', 'godot/scenes'].filter((d) => fs.existsSync(path.join(root, d)))) {
  for (const f of fs.readdirSync(path.join(root, d), { recursive: true })) {
    if (!String(f).endsWith('.gd')) continue;
    const m = fs.readFileSync(path.join(root, d, String(f)), 'utf8').match(/^class_name\s+(\w+)/m);
    if (m) live.add(m[1]);
  }
}
const bad = [];
for (const d of dirs) {
  for (const f of fs.readdirSync(path.join(root, d))) {
    if (!f.endsWith('.gd')) continue;
    fs.readFileSync(path.join(root, d, f), 'utf8').split(/\r?\n/).forEach((line, i) => {
      // Drop comments and string contents other than resource paths.
      const code = line.replace(/#.*$/, '');
      const hits = [];
      if (/res:\/\/(ui|scenes)\//.test(code)) hits.push('a ui/ or scenes/ path');
      for (const w of code.replace(/"(?!res:)[^"]*"/g, '""').match(/\b[A-Z]\w+\b/g) ?? []) if (live.has(w)) hits.push(w);
      if (hits.length) bad.push(`${d}/${f}:${i + 1}: ${hits.join(', ')}\n    ${line.trim()}`);
    });
  }
}
if (bad.length) {
  console.log(`Core reaches into Live (${bad.length}):\n` + bad.join('\n'));
  process.exit(1);
}
console.log(live.size
  ? `core boundary: godot/core and godot/cli use none of Live's ${live.size} classes and no ui/ or scenes/ path`
  : 'core boundary: Live is not in this folder; godot/core and godot/cli name no ui/ or scenes/ path');
