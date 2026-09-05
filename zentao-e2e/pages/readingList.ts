import { Page, Locator, expect } from '@playwright/test'

/** Reading → Reading List（/reading/list），以及从这里进入某台仪器的 Reading History */
export class ReadingListPage {
  constructor(private readonly page: Page) {}

  get instrumentId(): Locator {
    return this.page.getByRole('textbox', { name: 'Instrument ID' })
  }

  async open() {
    await this.page.goto('/reading/list')
    await this.instrumentId.waitFor()
  }

  /** 从左侧菜单进（用例 VMP-READING-001 明确要求走菜单，不是直接敲 URL） */
  async openViaMenu() {
    await this.page.goto('/')
    await this.page.getByRole('menuitem', { name: 'Reading', exact: true }).click()
    await this.page.getByRole('menuitem', { name: 'Reading List' }).click()
    await this.instrumentId.waitFor()
  }

  async search(instrumentId: string): Promise<Locator> {
    await this.instrumentId.fill(instrumentId)
    await this.page.getByRole('button', { name: 'Search', exact: true }).click()
    const row = this.page.getByRole('row', { name: new RegExp(escapeRe(instrumentId)) })
    await expect(row).toBeVisible()
    return row
  }

  /** 行上的 Check 按钮切到 Reading History 页签 */
  async openReadingHistory(instrumentId: string) {
    const row = await this.search(instrumentId)
    await row.getByRole('button', { name: 'Check' }).click()
    await expect(this.page.getByRole('tab', { name: 'Reading History' })).toHaveAttribute(
      'aria-selected',
      'true'
    )
    await expect(this.page.getByRole('button', { name: 'Add Reading' })).toBeVisible()
  }

  get readingHistoryRows(): Locator {
    // Reading History 页签里的数据表格（表头行不算）
    return this.page.locator('.el-table__body tr.el-table__row')
  }
}

function escapeRe(s: string) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}
