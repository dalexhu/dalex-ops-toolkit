import 'dotenv/config'

const BASE = process.env.ZENTAO_URL
const ACCOUNT = process.env.ZENTAO_ACCOUNT
const PASSWORD = process.env.ZENTAO_PASSWORD

let token = null

export async function login() {
  if (token) return token
  if (!BASE || !ACCOUNT || !PASSWORD) throw new Error('缺少 ZENTAO_URL / ZENTAO_ACCOUNT / ZENTAO_PASSWORD（见 .env）')
  const res = await fetch(`${BASE}/tokens`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ account: ACCOUNT, password: PASSWORD })
  })
  if (res.status !== 201) throw new Error(`禅道换 token 失败：HTTP ${res.status}`)
  token = (await res.json()).token
  return token
}

export async function api(path, init = {}) {
  const t = await login()
  const res = await fetch(`${BASE}${path}`, {
    ...init,
    headers: { Token: t, 'Content-Type': 'application/json', ...(init.headers || {}) }
  })
  const text = await res.text()
  let body = null
  try {
    body = text ? JSON.parse(text) : null
  } catch {
    body = text
  }
  return { status: res.status, body }
}

/** 列出产品下的用例。注意返回里的 id 是 `case_3605` 这种串，数字 ID 在 caseID */
export async function listCases(productId, limit = 2000) {
  const { status, body } = await api(`/products/${productId}/testcases?limit=${limit}&page=1`)
  if (status !== 200) throw new Error(`拉用例列表失败：HTTP ${status}`)
  return body
}

/** 用例明细，含步骤。只吃数字 ID */
export async function getCase(caseId) {
  const { status, body } = await api(`/testcases/${caseId}`)
  if (status !== 200) throw new Error(`拉用例 ${caseId} 失败：HTTP ${status}`)
  return body
}

/**
 * 回写一次执行结果。steps 顺序必须和用例步骤一致（group 类型的步骤后端会跳过）。
 * testtask 传 0 表示不挂测试单，直接记一次用例执行。
 */
export async function postResult(caseId, steps, testtask = 0) {
  const q = testtask ? `?testtask=${testtask}` : ''
  return api(`/testcases/${caseId}/results${q}`, {
    method: 'POST',
    body: JSON.stringify({ steps })
  })
}

/** 并发池，别把禅道打挂 */
export async function pool(items, size, fn) {
  const out = new Array(items.length)
  let i = 0
  await Promise.all(
    Array.from({ length: Math.min(size, items.length) }, async () => {
      while (i < items.length) {
        const idx = i++
        out[idx] = await fn(items[idx], idx)
      }
    })
  )
  return out
}
