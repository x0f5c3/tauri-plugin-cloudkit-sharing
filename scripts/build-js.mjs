import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { spawnSync } from 'node:child_process'

const root = new URL('..', import.meta.url).pathname
const dist = join(root, 'dist-js')
const work = join(root, '.js-build')
rmSync(dist, { recursive: true, force: true })
rmSync(work, { recursive: true, force: true })
mkdirSync(dist, { recursive: true })

function run(args) {
  const result = spawnSync('node_modules/.bin/tsc', args, { cwd: root, stdio: 'inherit' })
  if (result.status !== 0) process.exit(result.status ?? 1)
}

run(['--noEmit', 'false', '--declaration', '--emitDeclarationOnly', '--declarationDir', 'dist-js'])
run(['--noEmit', 'false', '--declaration', 'false', '--outDir', '.js-build/esm'])
run(['--noEmit', 'false', '--declaration', 'false', '--module', 'commonjs', '--moduleResolution', 'node', '--outDir', '.js-build/cjs'])

for (const file of ['index.js', 'bindings.js']) {
  cpSync(join(work, 'esm', file), join(dist, file))
}
writeFileSync(
  join(dist, 'index.js'),
  readFileSync(join(dist, 'index.js'), 'utf8').replaceAll('./bindings', './bindings.js'),
)
for (const file of ['bindings.js']) {
  cpSync(join(work, 'cjs', file), join(dist, file.replace('.js', '.cjs')))
}
const cjsIndex = readFileSync(join(work, 'cjs', 'index.js'), 'utf8').replaceAll('./bindings', './bindings.cjs')
writeFileSync(join(dist, 'index.cjs'), cjsIndex)
