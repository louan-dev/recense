// T-0093: localhost on an iPad is the iPad itself, so a localhost link to the editor can never open there.
// The iPad reaches Draftpad inside the app (bundled editor.html, offline) or at the Worker's /main/editor/ page.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const SKIP = new Set(['node_modules', 'dist', '.git', 'test', 'worktrees']);

function* walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (SKIP.has(e.name)) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) yield* walk(p);
    else if (/\.(md|swift|js|mjs|html|json)$/.test(e.name)) yield p;
  }
}

test('T-0093: no app, README or source hands out a localhost:8787 editor link', () => {
  const hits = [];
  for (const d of ['mobile', 'strip', 'editor', 'library/src']) {
    const base = path.join(root, d);
    if (!fs.existsSync(base)) continue;
    for (const f of walk(base)) {
      if (/localhost:8787\/editor/.test(fs.readFileSync(f, 'utf8'))) hits.push(path.relative(root, f));
    }
  }
  assert.deepEqual(hits, []);
});

test('T-0093: the iOS app bundles the editor page (works with no network)', () => {
  const pbx = fs.readFileSync(path.join(root, 'mobile/ios/GalleryFiles.xcodeproj/project.pbxproj'), 'utf8');
  assert.match(pbx, /A0C0FFEE00000000000000D7 = \{isa = PBXBuildFile/);
  const swift = fs.readFileSync(path.join(root, 'mobile/HostApp/iOS/Draftpad.swift'), 'utf8');
  assert.match(swift, /forResource: "editor", withExtension: "html"/);
});
