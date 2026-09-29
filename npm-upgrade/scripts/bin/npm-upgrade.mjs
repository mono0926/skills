#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import https from 'node:https';

function parseArgs(args) {
  const options = {
    help: false,
    path: '.',
    fix: true,
    verify: true,
    audit: true,
  };

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--help' || arg === '-h') {
      options.help = true;
    } else if (arg === '--path' || arg === '-p') {
      options.path = args[++i] || '.';
    } else if (arg === '--no-fix') {
      options.fix = false;
    } else if (arg === '--no-verify') {
      options.verify = false;
    } else if (arg === '--no-audit') {
      options.audit = false;
    }
  }
  return options;
}

function findGitRoot(startDir) {
  let current = path.resolve(startDir);
  while (true) {
    if (fs.existsSync(path.join(current, '.git'))) {
      return current;
    }
    const parent = path.dirname(current);
    if (parent === current) {
      break;
    }
    current = parent;
  }
  return null;
}

function runCmd(command, args, options = {}) {
  const result = spawnSync(command, args, {
    stdio: 'pipe',
    encoding: 'utf-8',
    ...options,
  });
  return result;
}

function detectPackageManager(projectDir) {
  if (fs.existsSync(path.join(projectDir, 'pnpm-lock.yaml'))) {
    return 'pnpm';
  }
  if (fs.existsSync(path.join(projectDir, 'yarn.lock'))) {
    return 'yarn';
  }
  return 'npm';
}

function collectDirectDependencies(pkgJsonPath) {
  const directDeps = new Set();
  if (!fs.existsSync(pkgJsonPath)) return directDeps;
  try {
    const content = JSON.parse(fs.readFileSync(pkgJsonPath, 'utf-8'));
    if (content.dependencies) {
      Object.keys(content.dependencies).forEach((pkg) => directDeps.add(pkg));
    }
    if (content.devDependencies) {
      Object.keys(content.devDependencies).forEach((pkg) => directDeps.add(pkg));
    }
    if (content.optionalDependencies) {
      Object.keys(content.optionalDependencies).forEach((pkg) => directDeps.add(pkg));
    }
  } catch (e) {
    console.error(`Warning: Failed to parse ${pkgJsonPath}: ${e.message}`);
  }
  return directDeps;
}

function parsePackageLock(lockContent) {
  const map = new Map();
  try {
    const lock = JSON.parse(lockContent);
    if (lock.packages) {
      // lockfileVersion 2 or 3
      for (const [key, pkgData] of Object.entries(lock.packages)) {
        if (!key || key === '') continue;
        // Top-level dependencies in packages: "node_modules/pkgName" or "node_modules/@scope/pkgName"
        const prefix = 'node_modules/';
        if (key.startsWith(prefix) && !key.slice(prefix.length).includes('node_modules/')) {
          const pkgName = key.slice(prefix.length);
          if (pkgData && pkgData.version) {
            map.set(pkgName, pkgData.version);
          }
        }
      }
    } else if (lock.dependencies) {
      // lockfileVersion 1
      for (const [pkgName, pkgData] of Object.entries(lock.dependencies)) {
        if (pkgData && pkgData.version) {
          map.set(pkgName, pkgData.version);
        }
      }
    }
  } catch (_) {}
  return map;
}

function parsePnpmLock(content) {
  const map = new Map();
  const lines = content.split('\n');
  // Simple extraction for pnpm lockfile
  for (const line of lines) {
    const match = line.match(/^ {2}\/?(@?[^@\s:]+)@([0-9a-zA-Z.-]+):/);
    if (match) {
      map.set(match[1], match[2]);
    }
  }
  return map;
}

function parseYarnLock(content) {
  const map = new Map();
  const lines = content.split('\n');
  let currentPkg = null;
  for (const line of lines) {
    if (line && !line.startsWith(' ') && line.includes(':')) {
      const match = line.match(/^"?(@?[^@\s",:]+)@/);
      if (match) {
        currentPkg = match[1];
      }
    } else if (currentPkg && line.trim().startsWith('version')) {
      const verMatch = line.match(/version\s+"?([^"\s]+)"?/);
      if (verMatch) {
        map.set(currentPkg, verMatch[1]);
        currentPkg = null;
      }
    }
  }
  return map;
}

function parseLockFile(content, manager) {
  if (!content) return new Map();
  if (manager === 'pnpm') return parsePnpmLock(content);
  if (manager === 'yarn') return parseYarnLock(content);
  return parsePackageLock(content);
}

function getLockFilePath(projectDir, manager) {
  if (manager === 'pnpm') return path.join(projectDir, 'pnpm-lock.yaml');
  if (manager === 'yarn') return path.join(projectDir, 'yarn.lock');
  return path.join(projectDir, 'package-lock.json');
}

async function fetchPackageMetadata(packageName) {
  return new Promise((resolve) => {
    const url = `https://registry.npmjs.org/${encodeURIComponent(packageName)}`;
    https.get(
      url,
      {
        headers: { 'User-Agent': 'npm-upgrade-helper/1.0.0' },
        timeout: 5000,
      },
      (res) => {
        if (res.statusCode !== 200) {
          res.resume();
          return resolve(null);
        }
        let data = '';
        res.on('data', (chunk) => (data += chunk));
        res.on('end', () => {
          try {
            const json = JSON.parse(data);
            let repoUrl = null;
            if (json.repository) {
              if (typeof json.repository === 'string') {
                repoUrl = json.repository;
              } else if (json.repository.url) {
                repoUrl = json.repository.url;
              }
            }
            if (repoUrl) {
              repoUrl = repoUrl
                .replace(/^git\+/, '')
                .replace(/\.git$/, '')
                .replace(/^git:\/\//, 'https://');
            }
            resolve({
              description: json.description || null,
              homepage: json.homepage || null,
              repoUrl: repoUrl || null,
            });
          } catch (_) {
            resolve(null);
          }
        });
      }
    ).on('error', () => resolve(null));
  });
}

async function main() {
  const options = parseArgs(process.argv.slice(2));

  if (options.help) {
    console.log(`
Usage: npm-upgrade [options]

Options:
  -h, --help            Show usage information
  -p, --path <path>     Path to the Node.js project directory (default: ".")
  --no-fix              Skip running lint --fix / formatting
  --no-verify           Skip running build / test verification
  --no-audit            Skip running npm audit
`);
    process.exit(0);
  }

  const projectDir = path.resolve(process.cwd(), options.path);
  if (!fs.existsSync(projectDir)) {
    console.error(`Error: Project directory does not exist: ${projectDir}`);
    process.exit(1);
  }

  const pkgJsonPath = path.join(projectDir, 'package.json');
  if (!fs.existsSync(pkgJsonPath)) {
    console.error(`Error: package.json not found in: ${projectDir}`);
    process.exit(1);
  }

  const gitRoot = findGitRoot(projectDir);
  if (!gitRoot) {
    console.error(`Error: Git repository root not found from: ${projectDir}`);
    process.exit(1);
  }

  console.log(`Git repository root identified: ${gitRoot}`);
  console.log(`Project directory: ${projectDir}`);

  // 1. 未コミット変更のチェック
  console.log('Checking for uncommitted changes in Git repository...');
  const statusRes = runCmd('git', ['status', '--porcelain'], { cwd: gitRoot });
  if (statusRes.stdout.trim().length > 0) {
    console.error('Error: You have uncommitted changes. Please commit or stash them first.');
    process.exit(1);
  }

  const manager = detectPackageManager(projectDir);
  console.log(`Detected package manager: ${manager}`);

  const directDeps = collectDirectDependencies(pkgJsonPath);
  console.log(`Found ${directDeps.size} direct dependencies in package.json.`);

  // 2. ブランチの作成とチェックアウト
  const now = new Date();
  const dateStr = now.toISOString().slice(0, 10).replace(/-/g, '');
  const branchName = `chore/deps/upgrade-npm-packages-${dateStr}`;
  console.log(`Creating topic branch: ${branchName}...`);
  const checkoutRes = runCmd('git', ['checkout', '-b', branchName], { cwd: gitRoot });
  if (checkoutRes.status !== 0) {
    console.error(`Error: Failed to create branch ${branchName}: ${checkoutRes.stderr}`);
    process.exit(1);
  }

  // ロックファイルの読み込み
  const lockFilePath = getLockFilePath(projectDir, manager);
  let oldLockContent = '';
  if (fs.existsSync(lockFilePath)) {
    console.log(`Reading existing lockfile: ${path.basename(lockFilePath)}...`);
    oldLockContent = fs.readFileSync(lockFilePath, 'utf-8');
  }
  const oldLockMap = parseLockFile(oldLockContent, manager);

  // 3. アップグレード実行
  console.log('\nUpgrading packages to latest versions with npm-check-updates...');
  let ncuCmd = 'npx';
  let ncuArgs = ['--yes', 'npm-check-updates', '-u'];
  if (manager === 'pnpm') {
    ncuCmd = 'pnpm';
    ncuArgs = ['dlx', 'npm-check-updates', '-u'];
  } else if (manager === 'yarn') {
    ncuCmd = 'yarn';
    ncuArgs = ['dlx', 'npm-check-updates', '-u'];
  }

  const isWin = process.platform === 'win32';
  const ncuRes = spawnSync(ncuCmd, ncuArgs, {
    cwd: projectDir,
    stdio: 'inherit',
    shell: isWin,
  });
  if (ncuRes.status !== 0) {
    console.error('Error: npm-check-updates failed.');
    process.exit(1);
  }

  console.log(`\nInstalling updated dependencies using ${manager}...`);
  let installCmd = manager;
  let installArgs = ['install'];
  const installRes = spawnSync(installCmd, installArgs, {
    cwd: projectDir,
    stdio: 'inherit',
    shell: isWin,
  });
  if (installRes.status !== 0) {
    console.error(`Error: ${manager} install failed.`);
    process.exit(1);
  }

  // 4. 新しいロックファイルの読み込みと差分比較
  if (!fs.existsSync(lockFilePath)) {
    console.error(`Error: Lockfile not found after upgrade: ${lockFilePath}`);
    process.exit(1);
  }
  const newLockContent = fs.readFileSync(lockFilePath, 'utf-8');
  const newLockMap = parseLockFile(newLockContent, manager);

  const upgradedPackages = [];
  for (const [pkgName, newVer] of newLockMap.entries()) {
    const oldVer = oldLockMap.get(pkgName);
    if (oldVer && oldVer !== newVer) {
      upgradedPackages.push({
        name: pkgName,
        oldVersion: oldVer,
        newVersion: newVer,
        isDirect: directDeps.has(pkgName),
      });
    }
  }

  // もしロックファイルで検知できなくても package.json で変更された直接依存があれば追加
  const postPkgDeps = collectDirectDependencies(pkgJsonPath);
  for (const pkgName of postPkgDeps) {
    if (!upgradedPackages.some((p) => p.name === pkgName)) {
      const oldVer = oldLockMap.get(pkgName) || 'unknown';
      const newVer = newLockMap.get(pkgName) || 'latest';
      if (oldVer !== newVer) {
        upgradedPackages.push({
          name: pkgName,
          oldVersion: oldVer,
          newVersion: newVer,
          isDirect: true,
        });
      }
    }
  }

  if (upgradedPackages.length === 0) {
    console.log('\nNo packages were upgraded.');
    runCmd('git', ['checkout', '-'], { cwd: gitRoot });
    runCmd('git', ['branch', '-D', branchName], { cwd: gitRoot });
    return;
  }

  console.log(`\nFound ${upgradedPackages.length} upgraded packages.`);

  // 5. npm レジストリからメタデータ（リポジトリURL等）を取得
  console.log('Fetching package metadata from npm registry concurrently...');
  await Promise.all(
    upgradedPackages.map(async (pkg) => {
      const meta = await fetchPackageMetadata(pkg.name);
      if (meta) {
        pkg.repoUrl = meta.repoUrl;
        pkg.homepage = meta.homepage;
        pkg.description = meta.description;
      }
      pkg.npmUrl = `https://www.npmjs.com/package/${pkg.name}`;
      if (pkg.repoUrl && pkg.repoUrl.includes('github.com')) {
        pkg.changelogUrl = `${pkg.repoUrl}/releases`;
      } else {
        pkg.changelogUrl = pkg.npmUrl;
      }
    })
  );

  // 6. npm audit によるセキュリティ監査（オプション）
  let auditSummary = null;
  if (options.audit && manager === 'npm') {
    console.log('\nRunning npm audit --json for security checks...');
    const auditRes = runCmd('npm', ['audit', '--json'], { cwd: projectDir });
    try {
      const auditJson = JSON.parse(auditRes.stdout || '{}');
      if (auditJson.metadata && auditJson.metadata.vulnerabilities) {
        auditSummary = auditJson.metadata.vulnerabilities;
      }
    } catch (_) {}
  }

  // 7. 結果を JSON に出力（.npm_upgrade/changelog_diffs.json）
  const outDir = path.join(projectDir, '.npm_upgrade');
  if (!fs.existsSync(outDir)) {
    fs.mkdirSync(outDir, { recursive: true });
  }
  const outFile = path.join(outDir, 'changelog_diffs.json');
  const resultPayload = {
    manager,
    upgradedCount: upgradedPackages.length,
    packages: upgradedPackages,
    audit: auditSummary,
  };
  fs.writeFileSync(outFile, JSON.stringify(resultPayload, null, 2), 'utf-8');
  console.log(`Package diffs written to ${outFile}`);

  // 8. パッケージ更新のコミット
  console.log('\nCommitting package upgrade changes...');
  runCmd('git', ['add', '--all'], { cwd: gitRoot });
  const commitRes = runCmd('git', ['commit', '-m', 'chore(deps): パッケージの一括アップグレード'], { cwd: gitRoot });
  if (commitRes.status === 0) {
    console.log(`Package upgrade committed to branch ${branchName}.`);
  } else {
    console.log('No git changes to commit or commit failed.');
  }

  // 9. 自動修正 (lint --fix, format)
  if (options.fix) {
    console.log('\nChecking for automatic code fixes (lint --fix / format)...');
    let pkgJson = {};
    try {
      pkgJson = JSON.parse(fs.readFileSync(pkgJsonPath, 'utf-8'));
    } catch (_) {}

    const scripts = pkgJson.scripts || {};
    let fixRan = false;

    if (scripts['lint:fix']) {
      console.log('Running npm run lint:fix...');
      runCmd('npm', ['run', 'lint:fix'], { cwd: projectDir });
      fixRan = true;
    } else if (scripts['lint']) {
      console.log('Running npm run lint -- --fix...');
      runCmd('npm', ['run', 'lint', '--', '--fix'], { cwd: projectDir });
      fixRan = true;
    }

    if (scripts['format']) {
      console.log('Running npm run format...');
      runCmd('npm', ['run', 'format'], { cwd: projectDir });
      fixRan = true;
    }

    if (fixRan) {
      const fixStatus = runCmd('git', ['status', '--porcelain'], { cwd: gitRoot });
      if (fixStatus.stdout.trim().length > 0) {
        console.log('Committing automatic fixes...');
        runCmd('git', ['add', '--all'], { cwd: gitRoot });
        runCmd('git', ['commit', '-m', 'fix(deps): パッケージ変更に伴う自動修正 (lint/format)'], { cwd: gitRoot });
        console.log('Automatic fixes committed.');
      } else {
        console.log('No automatic code fixes were produced.');
      }
    }
  }

  // 10. 静的検証 (build / test)
  if (options.verify) {
    console.log('\nRunning static verification (build / test)...');
    let pkgJson = {};
    try {
      pkgJson = JSON.parse(fs.readFileSync(pkgJsonPath, 'utf-8'));
    } catch (_) {}

    const scripts = pkgJson.scripts || {};
    if (scripts['build']) {
      console.log('Running build check (npm run build)...');
      const buildRes = spawnSync(manager, ['run', 'build'], {
        cwd: projectDir,
        stdio: 'inherit',
        shell: isWin,
      });
      if (buildRes.status !== 0) {
        console.warn('Warning: Build command failed. Manual review will be required.');
      } else {
        console.log('Build succeeded.');
      }
    }

    if (scripts['test']) {
      console.log('Running test check (npm test)...');
      const testRes = spawnSync(manager, ['test'], {
        cwd: projectDir,
        stdio: 'inherit',
        shell: isWin,
      });
      if (testRes.status !== 0) {
        console.warn('Warning: Test command failed. Manual review will be required.');
      } else {
        console.log('Tests passed.');
      }
    }
  }

  console.log('\n=== npm-upgrade helper script finished successfully ===');
}

main().catch((err) => {
  console.error(`Unexpected error: ${err.message}`);
  process.exit(1);
});
