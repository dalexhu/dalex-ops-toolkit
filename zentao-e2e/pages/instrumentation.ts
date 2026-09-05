import { Page, Locator, expect } from '@playwright/test'

/** Instrumentation → Instrument List / Instrument Details */
export class InstrumentationPage {
  constructor(private readonly page: Page) {}

  async openDetails(instrumentId: string) {
    await this.page.goto('/instrumentation/list')
    await this.page.getByRole('textbox', { name: 'Instrument ID' }).first().fill(instrumentId)
    await this.page.getByRole('button', { name: 'Search', exact: true }).click()
    const row = this.page.getByRole('row', { name: new RegExp(escapeRe(instrumentId)) })
    await expect(row.first()).toBeVisible({ timeout: 20_000 })
    // 列表行上没有链接，点第一格进详情（SPA 内切页签，URL 不变）
    await row.first().getByRole('cell').first().click()
    await expect(this.page.getByRole('tab', { name: 'Sensor Details' })).toBeVisible({
      timeout: 20_000
    })
  }

  /**
   * Instrument Details 下的子页签：Installation Set-up / Installation Details / Sensor Details ...
   * 返回可以直接交给 collectFields 的范围（main），字段是异步拉的，等数量稳定再返回。
   */
  async openTab(name: string, minFields = 10): Promise<Locator> {
    await this.page.getByRole('tab', { name, exact: true }).click()
    const scope = this.page.locator('main')
    await expect
      .poll(() => scope.locator('.el-form-item:visible').count(), { timeout: 20_000 })
      .toBeGreaterThan(minFields)
    return scope
  }
}

function escapeRe(s: string) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}
