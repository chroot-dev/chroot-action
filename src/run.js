'use strict'

const { spawnSync } = require('node:child_process')
const { join } = require('node:path')

module.exports = function run(script) {
  // TODO: macOS runners. Their rsync is Apple's openrsync, which sends
  // --delete-before and the guest's openrsync refuses it.
  if (process.platform !== 'linux') {
    console.log('::error::chroot-action runs on Linux runners only')
    process.exit(1)
  }

  // Inputs arrive as INPUT_SSH-KEY, a name sh cannot read.
  const env = { ...process.env }
  for (const [name, value] of Object.entries(process.env)) {
    if (name.startsWith('INPUT_'))
      env[name.replaceAll('-', '_')] = value
  }

  const r = spawnSync('sh', [join(__dirname, script)], { env, stdio: 'inherit' })
  if (r.error)
    console.log(`::error::${script}: ${r.error.message}`)
  process.exit(r.status ?? 1)
}
