#!/usr/bin/env node
/**
 * 把禅道某个产品的测试用例导出到 cases/ 下，给写自动化脚本当输入。
 *
 *   node scripts/export-cases.mjs                          # 只导列表
 *   node scripts/export-cases.mjs --steps                  # 连步骤一起导（请求数 = 用例数，慢）
 *   node scripts/export-cases.mjs --steps --filter VMP-READING
 *   node scripts/export-cases.mjs --steps --auto            # 只导 auto=auto 的
 */
import fs from 'node:fs'
import path from 'node:path'
import { listCases, getCase, pool } from './zentao.mjs'

const args = process.argv.slice(2)
const has = (f) => args.includes(f)
const val = (f) => {
  const i = args.indexOf(f)
  return i >= 0 ? args[i + 1] : null
}

const product = val('--product') || process.env.ZENTAO_PRODUCT || '3'
const filter = val('--filter')
const outDir = 'cases'

// 用例标题里普遍带 【路由/模块名】 前缀，按它分组正好对上前端页面
const ROUTE_RE = /^【(.+?)】/

const main = async () => {
  const data = await listCases(product)
  let cases = data.testcases || []
  console.log(`产品 ${product}：共 ${data.total} 条用例`)

  if (has('--auto')) cases = cases.filter((c) => c.auto === 'auto')
  if (filter) cases = cases.filter((c) => c.title.includes(filter))
  console.log(`筛选后 ${cases.length} 条`)

  if (has('--steps')) {
    const details = await pool(cases, 5, async (c) => {
      try {
        return await getCase(c.caseID)
      } catch (e) {
        console.warn(`  ! ${c.caseID} 明细拉取失败：${e.message}`)
        return null
      }
    })
    cases = cases.map((c, i) => ({ ...c, detail: details[i] }))
  }

  fs.mkdirSync(outDir, { recursive: true })
  // 文件名带上筛选条件，免得一次全量、一次筛选互相覆盖
  const suffix =
    (has('--auto') ? '-auto' : '') +
    (filter ? '-' + filter.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') : '')
  const jsonPath = path.join(outDir, `product-${product}${suffix}.json`)
  fs.writeFileSync(jsonPath, JSON.stringify(cases, null, 2))

  // 按路由分组的索引，方便挑下一批要自动化的模块
  const groups = new Map()
  for (const c of cases) {
    const m = ROUTE_RE.exec(c.title)
    const key = m ? m[1].replace(/\(#\d+\)$/, '') : `(无路由标签) module ${c.module}`
    if (!groups.has(key)) groups.set(key, [])
    groups.get(key).push(c)
  }
  const lines = [
    `# 禅道产品 ${product} 用例索引`,
    '',
    `共 ${cases.length} 条，按标题里的 【路由】 前缀分组。`,
    ''
  ]
  for (const [key, list] of [...groups].sort((a, b) => b[1].length - a[1].length)) {
    lines.push(`## ${key}（${list.length}）`, '')
    for (const c of list) {
      const auto = c.auto === 'auto' ? ' `auto`' : ''
      lines.push(`- [${c.caseID}] ${c.title}${auto} — ${c.stepNumber} 步，上次 ${c.lastRunResult || '未跑'}`)
      if (c.detail?.steps?.length) {
        for (const s of c.detail.steps) lines.push(`  - ${s.name}. ${s.desc} → ${s.expect}`)
      }
    }
    lines.push('')
  }
  const mdPath = path.join(outDir, `product-${product}${suffix}.md`)
  fs.writeFileSync(mdPath, lines.join('\n'))
  console.log(`写出 ${jsonPath} 和 ${mdPath}（${groups.size} 个分组）`)
}

main().catch((e) => {
  console.error(e.message)
  process.exit(1)
})
