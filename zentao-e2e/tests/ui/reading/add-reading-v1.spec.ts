import { test, expect, Browser, Page } from '@playwright/test'
import { ReadingListPage } from '../../../pages/readingList'
import { AddReadingDialog } from '../../../pages/addReadingDialog'

/**
 * VMP-READING-V1-001 / V1-002：拿 Version 1 和 Version 2 的 Add Reading 做对比。
 *
 * ⚠️ Version 1 站点这边还没有：v1 参考机（192.0.2.32）上 80/443 都没有服务在听，
 * 直连和经 75 跳转都连不上。所以这两条默认跳过，配好下面三个变量才会跑：
 *
 *   TERRA_V1_URL / TERRA_V1_USER / TERRA_V1_PASSWORD
 *
 * V1 侧的操作沿用 V2 的页面对象（同一产品的上一代，假定 UI 同形）。
 * 这部分没有在真实 V1 站点上验证过，第一次开起来大概率要按实际 DOM 调整。
 */

const INSTRUMENT_V2 = process.env.TERRA_INSTRUMENT || 'VP26-AEP Pond-BH-20260615210219670'
const INSTRUMENT_V1 = process.env.TERRA_V1_INSTRUMENT || 'VP26-Dyke 1-Cell 66 (E)-Test123'
const V1_URL = process.env.TERRA_V1_URL

/** 在 V1 站点上开一个独立上下文并登录 */
async function openV1(browser: Browser): Promise<{ page: Page; close: () => Promise<void> }> {
  const context = await browser.newContext({ baseURL: V1_URL })
  const page = await context.newPage()
  await page.goto('/login')
  await page.locator('input[autocomplete="username"]').fill(process.env.TERRA_V1_USER!)
  await page.locator('input[autocomplete="current-password"]').fill(process.env.TERRA_V1_PASSWORD!)
  const email = page.locator('input[type="email"]')
  if (await email.count()) await email.fill(process.env.TERRA_EMAIL || 'test@ops.ca')
  await page.getByRole('button', { name: /log ?in/i }).click()
  await expect(page).not.toHaveURL(/\/login/, { timeout: 30_000 })
  return { page, close: () => context.close() }
}

async function openAddReading(page: Page, instrument: string) {
  const list = new ReadingListPage(page)
  const dlg = new AddReadingDialog(page)
  await list.open()
  await list.openReadingHistory(instrument)
  await page.getByRole('button', { name: 'Add Reading' }).click()
  await dlg.expectOpen()
  return dlg
}

/** 用例第 5 步点名要比的那几个控件 */
const COMPARED = [
  'Reading Time',
  'Read By',
  'Comments',
  'Reading (Hz)',
  'Temperature',
  'Barometric (kPa)',
  'Logger Temperature'
]

async function controlKinds(dlg: AddReadingDialog): Promise<Record<string, string>> {
  const out: Record<string, string> = {}
  for (const label of COMPARED) {
    const el = dlg.field(label)
    out[label] = (await el.count())
      ? await el.evaluate((n: HTMLInputElement) => `${n.tagName.toLowerCase()}:${n.type}`)
      : 'missing'
  }
  return out
}

test.describe('VMP-READING 跨版本对比', () => {
  test.skip(!V1_URL, '没有配 TERRA_V1_URL：v1 参考机上没有可访问的 Version 1 站点')

  test(
    'VMP-READING-V1-001 Compare Add Reading field controls between Version 1 and Version 2',
    { annotation: { type: 'zentao', description: '1564' } },
    async ({ page, browser }) => {
      let v2!: AddReadingDialog
      let v1Kinds: Record<string, string> = {}
      let v2Kinds: Record<string, string> = {}
      const v1 = await openV1(browser)

      try {
        await test.step('Open Version 2 Add Reading for the configured instrument', async () => {
          v2 = await openAddReading(page, INSTRUMENT_V2)
        })
        await test.step('Collect Version 2 Add Reading field controls', async () => {
          v2Kinds = await controlKinds(v2)
        })
        let v1Dlg!: AddReadingDialog
        await test.step('Open Version 1 Add Reading for the configured instrument', async () => {
          v1Dlg = await openAddReading(v1.page, INSTRUMENT_V1)
        })
        await test.step('Collect Version 1 Add Reading field controls', async () => {
          v1Kinds = await controlKinds(v1Dlg)
        })
        await test.step('Compare Reading Time, Read By, Comments, raw reading, temperature, barometric, and logger temperature controls', async () => {
          for (const label of COMPARED) {
            expect(v2Kinds[label], `V2 缺少 ${label}`).not.toBe('missing')
            expect(v1Kinds[label], `V1 缺少 ${label}`).not.toBe('missing')
            expect(v1Kinds[label], `${label} 控件类型不一致`).toBe(v2Kinds[label])
          }
          // Saved Change Made: false —— 全程不点 Save
          await v2.close()
          await v1Dlg.close()
        })
      } finally {
        await v1.close()
      }
    }
  )

  test(
    'VMP-READING-V1-002 Compare Add Reading setup disclosure controls between Version 1 and Version 2',
    { annotation: { type: 'zentao', description: '1565' } },
    async ({ page, browser }) => {
      let v2!: AddReadingDialog
      let v1Dlg!: AddReadingDialog
      const v1 = await openV1(browser)

      try {
        await test.step('Open Version 2 Add Reading for the configured instrument', async () => {
          v2 = await openAddReading(page, INSTRUMENT_V2)
        })
        await test.step('Open Version 2 installation setup and calibration setup disclosure panels', async () => {
          await v2.showInstallationSetup.click()
          await v2.waitForPanel(v2.installationPanel)
          await v2.showCalibrationSetup.click()
          await v2.waitForPanel(v2.calibrationPanel)
        })
        await test.step('Open Version 1 Add Reading for the configured instrument', async () => {
          v1Dlg = await openAddReading(v1.page, INSTRUMENT_V1)
        })
        await test.step('Verify both versions show and open their setup disclosure controls', async () => {
          await expect(v2.root.getByRole('button', { name: 'Hide installation setup' })).toBeVisible()
          await expect(v2.root.getByRole('button', { name: 'Hide calibration setup' })).toBeVisible()
          await expect(v1Dlg.showInstallationSetup).toBeVisible()
          await v1Dlg.showInstallationSetup.click()
          await v1Dlg.waitForPanel(v1Dlg.installationPanel)
          await expect(v1Dlg.showCalibrationSetup).toBeVisible()
          await v1Dlg.showCalibrationSetup.click()
          await v1Dlg.waitForPanel(v1Dlg.calibrationPanel)
          await v2.close()
          await v1Dlg.close()
        })
      } finally {
        await v1.close()
      }
    }
  )
})
