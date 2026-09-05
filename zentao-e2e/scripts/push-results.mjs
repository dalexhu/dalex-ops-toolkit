#!/usr/bin/env node
/**
 * 把 Playwright 的 JSON 报告回写到禅道。
 *
 *   npx playwright test
 *   node scripts/push-results.mjs                  # 干跑，只打印要写什么
 *   node scripts/push-results.mjs --write          # 真写
 *   node scripts/push-results.mjs --write --testtask 12
 *
 * 映射规则：
 * - test 上的 annotation `zentao` 就是禅道用例的数字 ID
 * - 顶层 test.step 的顺序 == 禅道用例步骤的顺序，逐个写 pass/fail
 * - 步数对不上时按短的那边截断，并在输出里提示（用例改了步骤就会这样）
 */
import fs from 'node:fs'
import path from 'node:path'
import { getCase, postResult } from './zentao.mjs'

const args = process.argv.slice(2)
const WRITE = args.includes('--write')
const testtask = Number(
  (args.includes('--testtask') ? args[args.indexOf('--testtask') + 1] : null) ||
    process.env.ZENTAO_TESTTASK ||
    0
)
const REPORT_DIR = 'reports'
/** ui 和 api 是两次独立调用，各写一份报告，这里全都读进来 */
const reportPaths = () =>
  fs.existsSync(REPORT_DIR)
    ? fs
        .readdirSync(REPORT_DIR)
        .filter((f) => f.startsWith('results') && f.endsWith('.json'))
        .map((f) => path.join(REPORT_DIR, f))
    : []

const collectTests = (suite, acc = []) => {
  for (const s of suite.suites || []) collectTests(s, acc)
  for (const spec of suite.specs || []) {
    for (const t of spec.tests || []) {
      const r = t.results?.[t.results.length - 1]
      if (r) acc.push({ title: spec.title, annotations: t.annotations || [], result: r })
    }
  }
  return acc
}

const main = async () => {
  const paths = reportPaths()
  if (!paths.length) throw new Error(`${REPORT_DIR}/ 下没有报告，先跑 npm test`)
  const tests = []
  for (const p of paths) {
    const report = JSON.parse(fs.readFileSync(p, 'utf8'))
    for (const suite of report.suites || []) collectTests(suite, tests)
  }
  console.log(`读取报告：${paths.join(', ')}`)

  const tagged = tests.filter((t) => t.annotations.some((a) => a.type === 'zentao'))
  console.log(`报告里 ${tests.length} 个 test，其中 ${tagged.length} 个带禅道用例号`)
  if (testtask) console.log(`挂到测试单 ${testtask}`)
  else console.log('没指定测试单（--testtask），结果直接记在用例上')

  for (const t of tagged) {
    const caseId = t.annotations.find((a) => a.type === 'zentao').description

    // 跳过的用例没有产生任何证据，不往禅道写（写成 blocked 会假装跑过）
    if (t.result.status === 'skipped') {
      console.log(`  ${caseId} skipped 未回写  ${t.title}`)
      continue
    }

    const zcase = await getCase(caseId)
    const zSteps = (zcase.steps || []).filter((s) => s.type !== 'group')
    // JSON reporter 的 result.steps 只含我们自己写的 test.step（钩子不在里面）
    const pSteps = t.result.steps || []

    const n = Math.min(zSteps.length, pSteps.length)
    if (zSteps.length !== pSteps.length) {
      console.warn(
        `  ! ${caseId} 步数不一致：禅道 ${zSteps.length} 步 / 脚本 ${pSteps.length} 步，按 ${n} 步写`
      )
    }

    // 失败时定位到第一个出错的步骤：它记 fail，之前的 pass，之后的 blocked。
    // 报告里步骤级 error 不是每次都有，兜底用最后一个执行到的步骤。
    const passed = t.result.status === 'passed'
    let failIdx = -1
    if (!passed) {
      failIdx = pSteps.findIndex((s) => s.error)
      if (failIdx < 0) failIdx = Math.max(0, pSteps.length - 1)
    }
    const errMsg = String(
      pSteps[failIdx]?.error?.message || t.result.error?.message || t.result.status
    )
      .replace(/\u001b\[[0-9;]*m/g, '')
      .split('\n')
      .slice(0, 3)
      .join(' ')

    const steps = []
    for (let i = 0; i < n; i++) {
      if (passed || i < failIdx) steps.push({ result: 'pass', real: '' })
      else if (i === failIdx) steps.push({ result: 'fail', real: errMsg })
      else steps.push({ result: 'blocked', real: '前一步失败，未执行' })
    }
    // 脚本步数少于用例步数时，剩下的记 blocked（没跑到）
    for (let i = n; i < zSteps.length; i++) steps.push({ result: 'blocked', real: '脚本未覆盖' })

    const overall = t.result.status === 'passed' ? 'pass' : t.result.status
    console.log(`  ${caseId} ${overall.padEnd(7)} ${t.title}`)

    if (WRITE) {
      const { status, body } = await postResult(caseId, steps, testtask)
      if (status !== 200) console.error(`    写入失败 HTTP ${status}: ${JSON.stringify(body)}`)
      else console.log('    已写回禅道')
    }
  }

  if (!WRITE) console.log('\n（干跑，没有写入。加 --write 真正回写）')
}

main().catch((e) => {
  console.error(e.message)
  process.exit(1)
})
