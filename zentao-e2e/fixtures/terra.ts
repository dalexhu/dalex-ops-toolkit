import { test as base, APIRequestContext, request, expect } from '@playwright/test'

const SUCCESS = 20000

/** SMM 的告警参数码（INSTREAD-PARA-10） */
export const SMM = { PIEZO_ELEVATION: '2', RU: '3' } as const
/** 告警级别，后端返回 alarmLevel 1/2/3 */
export const LEVEL = { YELLOW: 1, ORANGE: 2, RED: 3 } as const

export interface AlarmRow {
  instrumentName: string
  sn: string
  alarmItem: string
  alarmType: string
  unit: string
  alarmLevel: number
  color: string
  currentValue: string
  realValue: number
  yellowCriteria: number
  redCriteria: number
  purpleCriteria: number
}

export interface AlarmCondition {
  sn: string
  alarmParam: string
  alarmType: 'regular' | 'rate' | 'difference'
  yellowThreshold: number
  orangeThreshold: number
  redThreshold: number
  criteriaUnit: string
}

/**
 * 直接打后端的客户端。
 * 注意：后端把 JWT 和 User-Agent 绑定，所以登录和后续请求必须用同一个 request context。
 */
export class TerraApi {
  private token: string | null = null

  constructor(private readonly ctx: APIRequestContext) {}

  static async create(): Promise<TerraApi> {
    // 必须用域名：nginx 的 /api 反代挂在 server_name 上。
    // 浏览器那边靠 Chromium 的 --host-resolver-rules 走内网，
    // 但 request context 不让覆盖 Host 头（会被忽略，落到默认 server 返回 HTML），
    // 所以这里只能按域名正常解析。
    const ctx = await request.newContext({
      baseURL: process.env.TERRA_API_URL || process.env.TERRA_URL,
      extraHTTPHeaders: { 'Accept-Language': 'en' }
    })
    const api = new TerraApi(ctx)
    await api.login()
    return api
  }

  async dispose() {
    await this.ctx.dispose()
  }

  async login() {
    const basic =
      'Basic ' +
      Buffer.from(`${process.env.TERRA_USER}:${process.env.TERRA_PASSWORD}`).toString('base64')
    const body = await this.post('/login', {
      username: process.env.TERRA_USER,
      password: basic,
      email: process.env.TERRA_EMAIL || 'test@ops.ca',
      portalType: 'business'
    })
    this.token = body.token
  }

  private headers() {
    return this.token ? { Authorization: `Bearer ${this.token}` } : {}
  }

  /** 统一拆包：后端成功时是 { code: 20000, results: ... } */
  private unwrap(url: string, status: number, json: any) {
    if (status !== 200 || json?.code !== SUCCESS) {
      throw new Error(`${url} 失败：HTTP ${status} code=${json?.code} ${JSON.stringify(json).slice(0, 300)}`)
    }
    return json.results
  }

  /** 后端出错时会返回 nginx 的 HTML 页面，直接 res.json() 只会得到看不懂的解析异常 */
  private async parse(url: string, res: { status(): number; text(): Promise<string> }) {
    const text = await res.text()
    try {
      return this.unwrap(url, res.status(), JSON.parse(text))
    } catch (e: any) {
      if (e instanceof SyntaxError) {
        throw new Error(`${url} 返回的不是 JSON：HTTP ${res.status()} ${text.slice(0, 200).replace(/\s+/g, ' ')}`)
      }
      throw e
    }
  }

  // 以 / 开头的 url 会覆盖 baseURL 的 path，所以 /api 前缀在这里拼
  private path(url: string) {
    return '/api' + url
  }

  async get(url: string, params?: Record<string, string | number>) {
    return this.parse(url, await this.ctx.get(this.path(url), { headers: this.headers(), params }))
  }

  async post(url: string, data?: unknown, params?: Record<string, string | number>) {
    return this.parse(url, await this.ctx.post(this.path(url), { headers: this.headers(), data: data as any, params }))
  }

  // ── 仪器 ──────────────────────────────────────────────

  async instrumentDetail(sn: string, type: string) {
    return this.get(`/v2/pm/instruments/instrumentDetail/${sn}/${type}`)
  }

  /** 按名字找一台仪器（thresholdConfig 的候选列表带 sn 和名字） */
  async findInstrumentByName(instrumentType: string, name: string) {
    const page = await this.post(
      '/pm/alarm/thresholdConfig/list/getInstrumentToAdd',
      { instrumentType },
      { pageNum: 1, pageSize: 200 }
    )
    const hit = (page.records || []).find((r: any) => r.instrumentName === name)
    if (!hit) throw new Error(`找不到仪器 ${name}（type=${instrumentType}）`)
    return hit
  }

  // ── 告警阈值配置 ──────────────────────────────────────

  async listAlarmConditions(sn: string) {
    const page = await this.post('/pm/alarm/thresholdConfig/list/search', { sn }, { pageNum: 1, pageSize: 100 })
    return (page.records || []).filter((r: any) => r.sn === sn)
  }

  /**
   * 建告警条件。saveOrUpdate 的响应不带 id，要清理得回头 search 一次拿 id。
   * effectiveAt 必须给且早于当前时间，否则条件不生效、告警永远不触发。
   */
  async createAlarmCondition(cond: AlarmCondition) {
    await this.post('/pm/alarm/thresholdConfig/list/saveOrUpdate', [
      { ...cond, scanInterval: 1, effectiveAt: '2020-01-01T00:00:00-07:00' }
    ])
  }

  async deleteAlarmConditions(sn: string): Promise<number> {
    const rows = await this.listAlarmConditions(sn)
    for (const row of rows) await this.post('/pm/alarm/thresholdConfig/delete', row)
    return rows.length
  }

  /**
   * 提交一条候选读数，返回它会触发哪些告警 —— 不落库。
   * 这是 QC Alarm 用例的核心：不用真的存读数就能验阈值。
   */
  async qcAlarmCheck(sn: string, instrumentType: string, reading: number | string): Promise<AlarmRow[]> {
    const readTime = new Date().toISOString().replace(/\.\d+Z$/, '-06:00')
    const zone = {
      sn,
      readTime,
      readBy: process.env.TERRA_USER,
      comment: null,
      instrumentType,
      instrumentTypeWithSub: instrumentType,
      reading: String(reading),
      id: null
    }
    return this.post('/v2/pm/reading/data/qcAlarmCheck', {
      readTime,
      sn,
      readType: instrumentType,
      instrumentType,
      readBy: process.env.TERRA_USER,
      comment: null,
      zoneReadingList: [zone]
    })
  }
}

export const test = base.extend<{ terra: TerraApi }>({
  terra: async ({}, use) => {
    const api = await TerraApi.create()
    await use(api)
    await api.dispose()
  }
})

export { expect }
