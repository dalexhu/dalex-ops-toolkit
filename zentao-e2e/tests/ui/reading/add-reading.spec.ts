import { test, expect } from '@playwright/test'
import { ReadingListPage } from '../../../pages/readingList'
import { AddReadingDialog } from '../../../pages/addReadingDialog'

/**
 * 对应禅道产品 3（Damon V2）里 auto=auto 的 [Integration] VMP-READING-* 用例。
 * 每个 test 用 annotation `zentao` 标出用例 ID，test.step 的顺序对应用例的步骤顺序，
 * scripts/push-results.mjs 按这个顺序把逐步结果写回禅道。
 *
 * 本轮试点只做只读断言，不落库；VMP-READING-012/013（保存后再删）留到后面。
 */

const INSTRUMENT = process.env.TERRA_INSTRUMENT || 'VP26-AEP Pond-BH-20260615210219670'

test.describe('VMP-READING（Add Reading）', () => {
  let list: ReadingListPage
  let dlg: AddReadingDialog

  test.beforeEach(async ({ page }) => {
    list = new ReadingListPage(page)
    dlg = new AddReadingDialog(page)
  })

  test.afterEach(async () => {
    await dlg.close()
  })

  test(
    'VMP-READING-001 Open Add Reading for an existing instrument',
    { annotation: { type: 'zentao', description: '1527' } },
    async ({ page }) => {
      await test.step('Click Reading', async () => {
        await page.goto('/')
        await page.getByRole('menuitem', { name: 'Reading', exact: true }).click()
        await expect(page.getByRole('menuitem', { name: 'Reading List' })).toBeVisible()
      })
      await test.step('Click Reading List', async () => {
        await page.getByRole('menuitem', { name: 'Reading List' }).click()
        await expect(list.instrumentId).toBeVisible()
      })
      await test.step(`Search Instrument ID ${INSTRUMENT}`, async () => {
        const row = await list.search(INSTRUMENT)
        await expect(row).toContainText(INSTRUMENT)
      })
      await test.step('Open Reading History', async () => {
        await list.openReadingHistory(INSTRUMENT)
      })
      await test.step('Click Add Reading', async () => {
        await page.getByRole('button', { name: 'Add Reading' }).click()
        await expect(dlg.root).toBeVisible()
      })
      await test.step('Verify Reading Data fields', async () => {
        await expect(dlg.readingHz).toBeVisible()
        await expect(dlg.readingBUnit).toBeVisible()
        await expect(dlg.temperature).toBeVisible()
        await expect(dlg.barometric).toBeVisible()
        for (const name of dlg.calculatedFieldNames) {
          await expect(dlg.calculated(name), `calculated field ${name}`).toBeDisabled()
        }
      })
    }
  )

  test(
    'VMP-READING-002 Verify mandatory numeric reading fields are required',
    { annotation: { type: 'zentao', description: '1528' } },
    async ({ page }) => {
      await test.step('Open Add Reading', async () => {
        await openAddReading(page, list, dlg)
      })
      await test.step('Focus Reading (Hz)', async () => {
        await dlg.readingHz.click()
      })
      await test.step('Click Save', async () => {
        await dlg.save.click()
      })
      await test.step('Verify required validation appears', async () => {
        await expect(dlg.validationMessages.filter({ hasText: /required/i }).first()).toBeVisible()
        await expect(dlg.root).toBeVisible() // 没保存，弹窗还在
      })
    }
  )

  test(
    'VMP-READING-003 Verify numeric reading fields reject text',
    { annotation: { type: 'zentao', description: '1529' } },
    async ({ page }) => {
      await test.step('Open Add Reading', async () => {
        await openAddReading(page, list, dlg)
      })
      await test.step('Enter abc into Reading (Hz)', async () => {
        await dlg.readingHz.fill('abc')
        await expect(dlg.readingHz).toHaveValue('abc')
      })
      await test.step('Enter abc into Temperature', async () => {
        await dlg.temperature.fill('abc')
        await expect(dlg.temperature).toHaveValue('abc')
      })
      await test.step('Verify numeric-type validation appears', async () => {
        await dlg.save.click()
        await expect(
          dlg.validationMessages.filter({ hasText: /numeric type/i }).first()
        ).toBeVisible()
        await expect(dlg.root).toBeVisible()
      })
    }
  )

  test(
    'VMP-READING-004 Verify Broken Temperature toggles Temperature state',
    { annotation: { type: 'zentao', description: '1530' } },
    async ({ page }) => {
      await test.step('Open Add Reading', async () => {
        await openAddReading(page, list, dlg)
      })
      await test.step('Check Broken Temperature', async () => {
        await dlg.brokenTemperatureLabel.click()
        await expect(dlg.brokenTemperature).toBeChecked()
      })
      await test.step('Verify Temperature is disabled with Broken Temp placeholder', async () => {
        await expect(dlg.temperature).toBeDisabled()
        await expect(dlg.temperature).toHaveAttribute('placeholder', /broken/i)
      })
      await test.step('Verify Temperature is editable', async () => {
        await dlg.brokenTemperatureLabel.click()
        await expect(dlg.brokenTemperature).not.toBeChecked()
        await expect(dlg.temperature).toBeEnabled()
      })
    }
  )

  test(
    'VMP-READING-009 Verify Read By dropdown opens options',
    { annotation: { type: 'zentao', description: '1553' } },
    async ({ page }) => {
      await test.step('Open Add Reading', async () => {
        await openAddReading(page, list, dlg)
      })
      await test.step('Verify Read By is enabled', async () => {
        await expect(dlg.readBy).toBeEnabled()
      })
      await test.step('Open Read By dropdown', async () => {
        await dlg.readByWrapper.click()
      })
      await test.step('Verify options are visible', async () => {
        await expect(dlg.readByOptions.first()).toBeVisible()
      })
    }
  )

  test(
    'VMP-READING-010 Verify Show installation setup disclosure',
    { annotation: { type: 'zentao', description: '1554' } },
    async ({ page }) => {
      await test.step('Open Add Reading', async () => {
        await openAddReading(page, list, dlg)
      })
      await test.step('Click Show installation setup', async () => {
        await dlg.showInstallationSetup.click()
      })
      await test.step('Verify installation details appear', async () => {
        await expect(dlg.root.getByRole('button', { name: 'Hide installation setup' })).toBeVisible()
        await expect(dlg.root.getByRole('textbox', { name: 'As Built Northing' })).toBeVisible()
        await expect(dlg.root.getByRole('textbox', { name: 'As Built Tip Elevation' })).toBeVisible()
      })
    }
  )

  test(
    'VMP-READING-011 Verify Show calibration setup disclosure',
    { annotation: { type: 'zentao', description: '1555' } },
    async ({ page }) => {
      await test.step('Open Add Reading', async () => {
        await openAddReading(page, list, dlg)
      })
      await test.step('Click Show calibration setup', async () => {
        await dlg.showCalibrationSetup.click()
      })
      await test.step('Verify calibration setup details appear', async () => {
        await expect(dlg.root.getByRole('button', { name: 'Hide calibration setup' })).toBeVisible()
        await expect(dlg.root.getByText('Calibration Calculation Method')).toBeVisible()
      })
    }
  )

  test(
    'VMP-READING-018 Verify required reading fields remain available after expanding detail panels',
    { annotation: { type: 'zentao', description: '1562' } },
    async ({ page }) => {
      await test.step('Open Add Reading', async () => {
        await openAddReading(page, list, dlg)
      })
      await test.step('Click Show installation setup', async () => {
        await dlg.showInstallationSetup.click()
      })
      await test.step('Click Show calibration setup', async () => {
        await dlg.showCalibrationSetup.click()
      })
      await test.step('Verify calculated reading fields are visible and read-only', async () => {
        await expect(dlg.readingHz).toBeVisible()
        await expect(dlg.temperature).toBeVisible()
        for (const name of dlg.calculatedFieldNames) {
          await expect(dlg.calculated(name), `calculated field ${name}`).toBeDisabled()
        }
      })
    }
  )
})

async function openAddReading(page: any, list: ReadingListPage, dlg: AddReadingDialog) {
  await list.open()
  await list.openReadingHistory(INSTRUMENT)
  await page.getByRole('button', { name: 'Add Reading' }).click()
  await dlg.expectOpen()
}
