#!/usr/bin/env node
/**
 * 轻量源码检查（CI 使用，不依赖 DevEco SDK）：
 *  1. LICENSE 存在且为 GPLv3 文本
 *  2. entry/src 下所有文本文件为合法 UTF-8、无替换字符（U+FFFD）
 *  3. .json 文件可被 JSON.parse（.json5 跳过）
 *  4. 必备社区文件存在
 *  5. 源码中不出现本机用户目录的绝对路径
 *
 * 完整构建与单测仍需 DevEco Studio（见 README / CONTRIBUTING）。
 */
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, extname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const errors = [];
const warnings = [];

function walk(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) out.push(...walk(full));
    else out.push(full);
  }
  return out;
}

function rel(p) {
  return relative(ROOT, p).split('\\').join('/');
}

// 1. LICENSE
const licensePath = join(ROOT, 'LICENSE');
if (!existsSync(licensePath)) {
  errors.push('缺少 LICENSE 文件');
} else {
  const text = readFileSync(licensePath, 'utf8');
  if (!text.includes('GNU GENERAL PUBLIC LICENSE') || !text.includes('Version 3')) {
    errors.push('LICENSE 不是 GPLv3 全文');
  }
}

// 2/3/5. 源码
const srcDir = join(ROOT, 'entry', 'src');
const files = existsSync(srcDir) ? walk(srcDir) : [];
const personalPath = /C:\\Users\\|\/Users\/[^/\s]+\//;
for (const file of files) {
  if (!/\.(ets|ts|json|json5|md|txt|xml)$/.test(file)) continue;
  const text = readFileSync(file, 'utf8');
  const name = rel(file);
  if (text.includes('\uFFFD')) errors.push(`${name}: 含 U+FFFD（编码损坏）`);
  if (personalPath.test(text)) errors.push(`${name}: 含个人绝对路径`);
  if (extname(file) === '.json') {
    const body = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
    try {
      JSON.parse(body);
    } catch (e) {
      errors.push(`${name}: 非法 JSON（${e.message}）`);
    }
  }
}

// 4. 社区文件
for (const f of ['README.md', 'CONTRIBUTING.md', 'CODE_OF_CONDUCT.md', 'SECURITY.md', 'CHANGELOG.md', '.gitignore']) {
  if (!existsSync(join(ROOT, f))) errors.push(`缺少 ${f}`);
}

// 5. .gitignore 关键忽略项
const giPath = join(ROOT, '.gitignore');
if (existsSync(giPath)) {
  const gi = readFileSync(giPath, 'utf8');
  for (const pat of ['local.properties', 'oh_modules', '*.p12', '*.p7b', '*.jks', '*.hap']) {
    if (!gi.includes(pat)) warnings.push(`.gitignore 未包含 ${pat}`);
  }
}

console.log(`检查文件：${files.length} 个（entry/src）`);
for (const w of warnings) console.log(`WARN  ${w}`);
for (const e of errors) console.log(`ERROR ${e}`);
if (errors.length > 0) {
  console.log(`\n检查失败：${errors.length} 个错误`);
  process.exit(1);
}
console.log('\n源码检查通过。');
