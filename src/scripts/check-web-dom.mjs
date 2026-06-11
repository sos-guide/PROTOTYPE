#!/usr/bin/env node
/**
 * SOS-GUIDE — Vérification statique des pages web (CI)
 *
 * Pour chaque page : extrait le <script> inline, vérifie sa syntaxe (new Function),
 * puis contrôle que chaque getElementById('X') référence un id présent quelque part
 * dans le fichier (HTML statique ou template literal généré).
 *
 * Usage : node src/scripts/check-web-dom.mjs
 * Sort avec un code != 0 si une incohérence est détectée.
 */
import { readFileSync } from 'node:fs';

const PAGES = [
  'src/web/index.html',
  'src/firstboot/starter.html',
];

let failures = 0;

for (const page of PAGES) {
  const html = readFileSync(page, 'utf8');

  // Scripts inline (on ignore les <script src=…>)
  const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
  if (scripts.length === 0) {
    console.error(`✘ ${page} : aucun <script> inline trouvé`);
    failures++;
    continue;
  }
  const js = scripts.join('\n');

  // 1. Syntaxe JS
  try {
    new Function(js);
    console.log(`✔ ${page} : syntaxe JS valide`);
  } catch (e) {
    console.error(`✘ ${page} : erreur de syntaxe JS — ${e.message}`);
    failures++;
  }

  // 2. Chaque getElementById doit correspondre à un id défini quelque part
  const used = new Set([...js.matchAll(/getElementById\(\s*['"]([\w-]+)['"]\s*\)/g)].map(m => m[1]));
  const defined = new Set([...html.matchAll(/id\s*=\s*["']?([\w-]+)/g)].map(m => m[1]));
  const missing = [...used].filter(id => !defined.has(id));
  if (missing.length) {
    console.error(`✘ ${page} : getElementById sans id correspondant → ${missing.join(', ')}`);
    failures++;
  } else {
    console.log(`✔ ${page} : ${used.size} getElementById, tous résolus`);
  }
}

process.exit(failures ? 1 : 0);
