// Loads the LawSpec prelude into a Claude Code session, once, the first time
// a tool call touches LawSpec work. Run by lawspec-prelude.sh, which is
// registered in .claude/settings.json for PreToolUse and SessionStart.
//
// The prelude is read from the installed compiler (`lawspec prelude --json`
// in lawspec/node_modules), never from a copy in the repository, so it always
// matches the LawSpec version package.json pins.
//
// Hook input arrives as JSON on stdin; context goes back to the model as
// `hookSpecificOutput.additionalContext`. Whatever happens, this exits 0 and
// prints either that JSON or nothing: a hook that fails would get in the way
// of the tool call it rides on.

import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

// Claude Code caps a hook's additionalContext at 10,000 characters and shows
// only a preview of anything longer, so the rendering has to fit.
const CONTEXT_CAP = 9_800

const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const lawspecDir = path.join(projectDir, 'lawspec')
const packageDir = path.join(lawspecDir, 'node_modules', 'lawspec')
const stateDir = path.join(os.tmpdir(), 'cake-lawspec-prelude')

function main() {
  const input = JSON.parse(fs.readFileSync(0, 'utf8'))
  const session = safeName(input.session_id ?? 'unknown-session')

  // A new, resumed, cleared or compacted session may have lost the prelude
  // from its context, so forget that it was loaded and let the next LawSpec
  // tool call load it again.
  if (input.hook_event_name === 'SessionStart') {
    forget(session)
    return
  }

  if (!isLawSpecWork(input)) return

  // A subagent has its own context, so it gets its own load.
  const agent = input.agent_id ? `${session}.${safeName(input.agent_id)}` : session
  const loaded = path.join(stateDir, `${agent}.loaded`)
  if (fs.existsSync(loaded)) return

  if (!fs.existsSync(path.join(packageDir, 'bin', 'lawspec.mjs'))) {
    // Say so once, and keep trying on later calls until LawSpec is installed.
    if (claim(path.join(stateDir, `${agent}.noticed`))) emit(input, notInstalledNotice())
    return
  }

  // Tool calls sent together run their hooks at the same time, so the marker
  // is claimed before the prelude is read: only one of them loads it.
  if (!claim(loaded)) return

  try {
    emit(input, render(readPrelude()))
  } catch (error) {
    // Nothing was loaded, so let a later call try again.
    fs.rmSync(loaded, { force: true })
    throw error
  }
}

// LawSpec work is a call on a file under lawspec/ or a .lawspec file, a call
// made from inside lawspec/, or a shell command or search that names lawspec.
function isLawSpecWork(input) {
  const cwd = input.cwd ?? projectDir
  const tool = input.tool_input ?? {}

  const inLawspec = (candidate) => {
    if (typeof candidate !== 'string' || candidate === '') return false
    const absolute = path.resolve(cwd, candidate)
    return (
      absolute === lawspecDir ||
      absolute.startsWith(lawspecDir + path.sep) ||
      absolute.endsWith('.lawspec')
    )
  }

  const namesLawspec = (text) => typeof text === 'string' && /\blawspec\b/i.test(text)

  return (
    inLawspec(cwd) ||
    inLawspec(tool.file_path) ||
    inLawspec(tool.path) ||
    namesLawspec(tool.command) ||
    namesLawspec(tool.pattern) ||
    namesLawspec(tool.glob)
  )
}

function readPrelude() {
  const version = JSON.parse(fs.readFileSync(path.join(packageDir, 'package.json'), 'utf8')).version

  // --no-turbo-fast-api-calls: the same flag the npm scripts pass, for the
  // same reason (lawspec/README.md, "Running LawSpec").
  const output = execFileSync(
    process.execPath,
    ['--no-turbo-fast-api-calls', path.join(packageDir, 'bin', 'lawspec.mjs'), 'prelude', '--json'],
    { cwd: lawspecDir, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 25_000 }
  )
  const { entries, lawSource } = JSON.parse(output)

  return {
    version,
    operations: entries.filter((entry) => entry.kind === 'operation'),
    laws: lawSource.split(/^(?=law ")/m).slice(1).map(parseLaw),
    lawSource
  }
}

// One law of the prelude's source, cut down to what applying it needs: its
// name, its parameters and constraints, and its definition. The description
// and rationale stay in the full source.
function parseLaw(block) {
  const collapse = (text) => text.replace(/\s+/g, ' ').trim()
  const name = block.match(/^law (".*)$/m)?.[1]?.trim()
  const header = block.match(/^law ".*\n([\s\S]*?)^is$/m)?.[1]
  const definition = block.match(/definition\s*:([\s\S]*?)end definition/)?.[1]

  if (name === undefined || header === undefined || definition === undefined) {
    // A shape this parser does not know, from a later LawSpec: give it whole.
    return { name: name ?? collapse(block).slice(0, 60), line: collapse(block) }
  }

  const signature = collapse(header)
  return { name, line: `${name}${signature ? ` ${signature}` : ''}: ${collapse(definition)}` }
}

function render(prelude) {
  const fullPath = writeFullSource(prelude)

  const head =
    `LawSpec prelude (LawSpec ${prelude.version}), loaded automatically because this tool call ` +
    'touches LawSpec work. It is read from the compiler installed in lawspec/node_modules ' +
    '(`npm run -s lawspec -- prelude`), so it is current for the pinned version; ' +
    'use these names rather than recalled ones.'

  const operationsHead = (detail) =>
    `Operations (${prelude.operations.length}): write one as prelude.<name>. The compiler ` +
    `reports names only, no signatures${detail}; for a signature, find a use in ` +
    'lawspec/laws/*.lawspec or lawspec/node_modules/lawspec/examples/.'

  const withDefinitions = prelude.operations
    .map((op) => (op.definition ? `${op.name}=${op.definition}` : op.name))
    .join(', ')
  const namesOnly = prelude.operations.map((op) => op.name).join(', ')

  const lawsHead = `Laws (${prelude.laws.length}): apply one with \`apply law "|name| arg ...\`.`
  const tail = `Full prelude source, with each law's description and rationale: ${fullPath}`

  // From most detail to least, the first rendering that fits the cap.
  const renderings = [
    [
      head,
      operationsHead('; `name=unit::definition` is a re-export of a library definition'),
      withDefinitions,
      lawsHead,
      prelude.laws.map((law) => law.line).join('\n'),
      tail
    ],
    [head, operationsHead(''), namesOnly, lawsHead, prelude.laws.map((law) => law.line).join('\n'), tail],
    [head, operationsHead(''), namesOnly, lawsHead, prelude.laws.map((law) => law.name).join(', '), tail]
  ].map((parts) => parts.join('\n\n'))

  return renderings.find((text) => text.length <= CONTEXT_CAP) ?? renderings.at(-1).slice(0, CONTEXT_CAP)
}

function writeFullSource(prelude) {
  const file = path.join(stateDir, `prelude-${safeName(prelude.version)}.lawspec`)
  const operations = prelude.operations
    .map((op) => `-- operation: ${op.qualifiedName}${op.definition ? ` = ${op.definition}` : ''}`)
    .join('\n')

  fs.mkdirSync(stateDir, { recursive: true })
  fs.writeFileSync(file, `${operations}\n\n${prelude.lawSource}`)
  return file
}

function notInstalledNotice() {
  return (
    'LawSpec prelude NOT loaded: LawSpec is not installed (lawspec/node_modules/lawspec is ' +
    'missing). Before writing or changing a .lawspec file, run `npm ci` in lawspec/; the prelude ' +
    'then loads itself on the next tool call that touches lawspec/. To read it by hand: ' +
    '`npm run -s lawspec -- prelude` in lawspec/.'
  )
}

function emit(input, additionalContext) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: { hookEventName: input.hook_event_name ?? 'PreToolUse', additionalContext }
    })
  )
}

// Creates the marker file, and says whether this call was the one to create
// it: `wx` fails if the file is already there, so of several calls racing for
// one marker exactly one wins.
function claim(file) {
  fs.mkdirSync(stateDir, { recursive: true })

  try {
    fs.writeFileSync(file, '', { flag: 'wx' })
    return true
  } catch (error) {
    if (error.code === 'EEXIST') return false
    throw error
  }
}

function forget(session) {
  if (!fs.existsSync(stateDir)) return

  for (const name of fs.readdirSync(stateDir)) {
    const isMarker = name.endsWith('.loaded') || name.endsWith('.noticed')
    if (isMarker && name.startsWith(`${session}.`)) fs.rmSync(path.join(stateDir, name), { force: true })
  }
}

function safeName(text) {
  return String(text).replace(/[^A-Za-z0-9_-]/g, '_')
}

try {
  main()
} catch {
  // Never fail the tool call this hook rides on.
}
