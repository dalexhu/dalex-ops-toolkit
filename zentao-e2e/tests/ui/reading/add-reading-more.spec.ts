import { test, expect, Page, Locator } from '@playwright/test'
import { ReadingListPage } from '../../../pages/readingList'
import { AddReadingDialog } from '../../../pages/addReadingDialog'
import { InstrumentationPage } from '../../../pages/instrumentation'
import { collectFields, comparable } from '../../../pages/fields'

/**
 * VMP-READING 余下的用例。与 vmp-reading.spec.ts 同样的约定：
 * annotation `zentao` = 禅道用例数字 ID，顶层 test.step 顺序 == 禅道用例步骤顺序。
 */

const INSTRUMENT = process.env.TERRA_INSTRUMENT || 'VP26-AEP Pond-BH-20260615210219670'
const OUTTAKE = process.env.TERRA_INSTRUMENT_OUTTAKE || 'OD_20250910_1'
const WITH_HISTORY = process.env.TERRA_INSTRUMENT_WITH_HISTORY || 'DP11-58'

/** 会真正落库的用例登记在这里，afterEach 兜底清掉（用例自身也会删一遍） */
let pending: { instrument: string; marker: string } | null = null

async function openAddReading(page: Page, instrument = INSTRUMENT) {
  const list = new ReadingListPage(page)
  const dlg = new AddReadingDialog(page)
  await list.open()
  await list.openReadingHistory(instrument)
  await page.getByRole('button', { name: 'Add Reading' }).click()
  await dlg.expectOpen()
  return dlg
}

function historyRows(page: Page) {
  return page.locator('#readingHistory .el-table__body tr.el-table__row')
}

/** 删掉 Reading History 里 Comment 命中 marker 的行 */
async function deleteRowsByMarker(page: Page, instrument: string, marker: string) {
  const list = new ReadingListPage(page)
  await list.open()
  await list.openReadingHistory(instrument)
  const target = historyRows(page).filter({ hasText: marker })
  for (let n = await target.count(); n > 0; n = await target.count()) {
    await target.first().getByRole('button', { name: 'Delete' }).click()
    const confirm = page.getByRole('button', { name: /^(OK|Confirm|Yes)$/ })
    if (await confirm.count()) await confirm.first().click()
    await expect(target).toHaveCount(n - 1, { timeout: 15_000 })
  }
}

test.describe('VMP-READING 补充', () => {
  test.afterEach(async ({ page }) => {
    if (!pending) return
    const { instrument, marker } = pending
    pending = null
    await deleteRowsByMarker(page, instrument, marker).catch(() => undefined)
  })

  test(
    'VMP-READING-005 Verify Suspicious Reading requires comments',
    { annotation: { type: 'zentao', description: '1531' } },
    async ({ page }) => {
      let dlg!: AddReadingDialog
      await test.step('Open Add Reading', async () => {
        dlg = await openAddReading(page)
      })
      await test.step('Fill valid reading data without comments', async () => {
        await dlg.readingHz.fill('2500')
        await dlg.temperature.fill('12')
        await expect(dlg.readingBUnit).not.toHaveValue('')
        await expect(dlg.comments).toHaveValue('')
      })
      await test.step('Check Suspicious Reading - Requires follow up', async () => {
        // 勾上之前必须确认真的勾上了，否则点 Save 会直接存成一条读数
        await dlg.setCheckbox(dlg.suspiciousReadingLabel, dlg.suspiciousReading, true)
      })
      await test.step('Verify comments required validation appears', async () => {
        await expect(dlg.suspiciousReading).toBeChecked()
        await expect(dlg.comments).toHaveValue('')
        await dlg.save.click()
        // 提示是 ElNotification（add.vue saveNext 里的 commentRequired），不是表单内联错误
        await expect(dlg.notifications.filter({ hasText: /comment is required/i })).toBeVisible({
          timeout: 15_000
        })
        await expect(dlg.root).toBeVisible()
      })
      await test.step('Uncheck Suspicious Reading', async () => {
        await dlg.setCheckbox(dlg.suspiciousReadingLabel, dlg.suspiciousReading, false)
      })
    }
  )

  test(
    'VMP-READING-006 Verify Abnormal Condition hides raw reading inputs',
    { annotation: { type: 'zentao', description: '1550' } },
    async ({ page }) => {
      let dlg!: AddReadingDialog
      await test.step('Open Add Reading', async () => {
        // 用例前置写的是 VWP 仪器，但 Abnormal Condition 只在 Outtake Drain 表单上
        // （readingForm/outtakeDrain.vue），所以这里换成 Outtake Drain 仪器
        dlg = await openAddReading(page, OUTTAKE)
      })
      await test.step('Check Abnormal Condition', async () => {
        await dlg.setCheckbox(dlg.abnormalConditionLabel, dlg.abnormalCondition, true)
      })
      await test.step('Verify raw reading inputs are hidden', async () => {
        await expect(dlg.field('Time 1 (s)')).toBeHidden()
        await expect(dlg.field('Volume 1 (L)')).toBeHidden()
      })
      await test.step('Verify raw reading inputs are visible', async () => {
        await dlg.setCheckbox(dlg.abnormalConditionLabel, dlg.abnormalCondition, false)
        await expect(dlg.field('Time 1 (s)')).toBeVisible()
        await expect(dlg.field('Volume 1 (L)')).toBeVisible()
      })
    }
  )

  test(
    'VMP-READING-007 Verify Abnormal Condition hides calculated reading fields',
    { annotation: { type: 'zentao', description: '1551' } },
    async ({ page }) => {
      let dlg!: AddReadingDialog
      await test.step('Open Add Reading', async () => {
        dlg = await openAddReading(page, OUTTAKE)
      })
      await test.step('Check Abnormal Condition', async () => {
        await dlg.setCheckbox(dlg.abnormalConditionLabel, dlg.abnormalCondition, true)
      })
      await test.step('Verify calculated fields are hidden', async () => {
        await expect(dlg.field('Average Time (s)')).toBeHidden()
        await expect(dlg.field('Average Volume (L)')).toBeHidden()
      })
      await test.step('Verify calculated fields are visible and read-only', async () => {
        await dlg.setCheckbox(dlg.abnormalConditionLabel, dlg.abnormalCondition, false)
        await expect(dlg.field('Average Time (s)')).toBeDisabled()
        await expect(dlg.field('Average Volume (L)')).toBeDisabled()
      })
    }
  )

  test(
    'VMP-READING-008 Verify Reading Time opens date-time picker',
    { annotation: { type: 'zentao', description: '1552' } },
    async ({ page }) => {
      let dlg!: AddReadingDialog
      await test.step('Open Add Reading', async () => {
        dlg = await openAddReading(page)
      })
      await test.step('Verify Reading Time has timestamp format', async () => {
        await expect(dlg.readingTime).toHaveValue(/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/)
      })
      await test.step('Click Reading Time', async () => {
        await dlg.readingTimeWrapper.click()
        await expect(dlg.datePickerPanel.first()).toBeVisible()
        await page.keyboard.press('Escape')
      })
    }
  )

  test(
    'VMP-READING-012 Verify saved Reading Hz record is deleted after verification',
    { annotation: { type: 'zentao', description: '1556' } },
    async ({ page }) => {
      const marker = `AUTOTEST-HZ-${Date.now()}`
      let dlg!: AddReadingDialog
      await test.step('Open Add Reading', async () => {
        dlg = await openAddReading(page)
      })
      await test.step('Fill valid Reading Hz data with unique AUTOTEST comment', async () => {
        await dlg.comments.fill(marker)
        await dlg.readingHz.fill('2500')
        await dlg.temperature.fill('12')
        // B Unit = Hz*Hz/1000，由前端自动算出来
        await expect(dlg.readingBUnit).not.toHaveValue('')
      })
      await test.step('Click Save', async () => {
        pending = { instrument: INSTRUMENT, marker }
        await dlg.save.click()
        await expect(dlg.notifications.filter({ hasText: /success/i }).first()).toBeVisible({
          timeout: 20_000
        })
        await dlg.close()
      })
      await test.step('Delete the saved row', async () => {
        const row = historyRows(page).filter({ hasText: marker })
        await expect(row).toHaveCount(1, { timeout: 20_000 })
        await row.getByRole('button', { name: 'Delete' }).click()
        const confirm = page.getByRole('button', { name: /^(OK|Confirm|Yes)$/ })
        if (await confirm.count()) await confirm.first().click()
      })
      await test.step('Verify the saved row is removed', async () => {
        await expect(historyRows(page).filter({ hasText: marker })).toHaveCount(0, {
          timeout: 20_000
        })
        pending = null
      })
    }
  )

  test(
    'VMP-READING-013 Verify saved B Unit record is deleted after verification',
    { annotation: { type: 'zentao', description: '1557' } },
    async ({ page }) => {
      const marker = `AUTOTEST-BU-${Date.now()}`
      let dlg!: AddReadingDialog
      await test.step('Open Add Reading', async () => {
        dlg = await openAddReading(page)
      })
      await test.step('Fill valid B Unit data with unique AUTOTEST comment', async () => {
        await dlg.comments.fill(marker)
        await dlg.readingBUnit.fill('6250')
        await dlg.temperature.fill('12')
        // 反过来由 B Unit 推 Hz
        await expect(dlg.readingHz).not.toHaveValue('')
      })
      await test.step('Click Save', async () => {
        pending = { instrument: INSTRUMENT, marker }
        await dlg.save.click()
        await expect(dlg.notifications.filter({ hasText: /success/i }).first()).toBeVisible({
          timeout: 20_000
        })
        await dlg.close()
      })
      await test.step('Delete the saved row', async () => {
        const row = historyRows(page).filter({ hasText: marker })
        await expect(row).toHaveCount(1, { timeout: 20_000 })
        await row.getByRole('button', { name: 'Delete' }).click()
        const confirm = page.getByRole('button', { name: /^(OK|Confirm|Yes)$/ })
        if (await confirm.count()) await confirm.first().click()
      })
      await test.step('Verify the saved row is removed', async () => {
        await expect(historyRows(page).filter({ hasText: marker })).toHaveCount(0, {
          timeout: 20_000
        })
        pending = null
      })
    }
  )

  test(
    'VMP-READING-014 Verify configured instrument has existing Reading History rows',
    { annotation: { type: 'zentao', description: '1558' } },
    async ({ page }) => {
      const list = new ReadingListPage(page)
      await test.step('Open Reading History for the configured instrument', async () => {
        // 用例点名的 VWP 仪器在 test2 上没有历史读数，这里用一台确有读数的
        await list.open()
        await list.openReadingHistory(WITH_HISTORY)
      })
      await test.step('Verify existing Reading History rows are visible', async () => {
        await expect(historyRows(page).first()).toBeVisible({ timeout: 20_000 })
      })
      await test.step('Verify Reading History data row count is greater than zero', async () => {
        expect(await historyRows(page).count()).toBeGreaterThan(0)
      })
    }
  )

  test(
    'VMP-READING-015 Verify Add Reading installation details match Instrumentation Installation Details',
    { annotation: { type: 'zentao', description: '1559' } },
    async ({ page }) => {
      const instr = new InstrumentationPage(page)
      let fromInstrumentation: Record<string, string> = {}
      let instrumentationScope!: Locator
      let dlg!: AddReadingDialog

      await test.step('Open Installation Setup for the configured instrument', async () => {
        await instr.openDetails(INSTRUMENT)
        await instr.openTab('Installation Set-up')
      })
      await test.step('Open Installation Details from Instrument Details', async () => {
        instrumentationScope = await instr.openTab('Installation Details')
      })
      await test.step('Collect the Instrumentation Installation Details values', async () => {
        fromInstrumentation = await collectFields(instrumentationScope)
        expect(Object.keys(fromInstrumentation).length).toBeGreaterThan(0)
      })
      await test.step('Open Add Reading', async () => {
        dlg = await openAddReading(page)
      })
      await test.step('Click Show installation setup', async () => {
        await dlg.showInstallationSetup.click()
        await dlg.waitForPanel(dlg.installationPanel)
      })
      await test.step('Verify Add Reading installation details contain the Instrumentation values', async () => {
        const fromDialog = await collectFields(dlg.installationPanel)
        const pairs = comparable(fromInstrumentation, fromDialog, INSTALLATION_FIELDS)
        expect(pairs.length, `没有可比对的安装字段（Instrumentation 侧全空）`).toBeGreaterThan(0)
        for (const [label, a, b] of pairs) expect(b, `字段 ${label}`).toBe(a)
      })
    }
  )

  test(
    'VMP-READING-016 Verify Add Reading calibration setup details match Instrumentation Sensor Details',
    { annotation: { type: 'zentao', description: '1560' } },
    async ({ page }) => {
      const instr = new InstrumentationPage(page)
      let fromInstrumentation: Record<string, string> = {}
      let instrumentationScope!: Locator
      let dlg!: AddReadingDialog

      await test.step('Open Sensor Details for the configured instrument', async () => {
        await instr.openDetails(INSTRUMENT)
        instrumentationScope = await instr.openTab('Sensor Details')
      })
      await test.step('Collect the Instrumentation Sensor Details values', async () => {
        fromInstrumentation = await collectFields(instrumentationScope)
        expect(Object.keys(fromInstrumentation).length).toBeGreaterThan(0)
      })
      await test.step('Open Add Reading', async () => {
        dlg = await openAddReading(page)
      })
      await test.step('Verify Add Reading calibration setup details contain the Instrumentation values', async () => {
        await dlg.showCalibrationSetup.click()
        await dlg.waitForPanel(dlg.calibrationPanel)
        const fromDialog = await collectFields(dlg.calibrationPanel)
        const pairs = comparable(fromInstrumentation, fromDialog, SENSOR_FIELDS)
        expect(pairs.length, `没有可比对的传感器字段（Instrumentation 侧全空）`).toBeGreaterThan(0)
        for (const [label, a, b] of pairs) expect(b, `字段 ${label}`).toBe(a)
      })
    }
  )

  test(
    'VMP-READING-017 Verify Add Reading shows the existing-data Instrument ID',
    { annotation: { type: 'zentao', description: '1561' } },
    async ({ page }) => {
      let dlg!: AddReadingDialog
      await test.step('Open Add Reading', async () => {
        dlg = await openAddReading(page)
      })
      await test.step(`Verify the Add Reading dialog contains Instrument ID ${INSTRUMENT}`, async () => {
        await expect(dlg.instrumentIdGroup).toContainText(INSTRUMENT)
      })
    }
  )

  test(
    'VMP-READING-019 Verify section labels in expanded Add Reading detail panels',
    { annotation: { type: 'zentao', description: '1563' } },
    async ({ page }) => {
      let dlg!: AddReadingDialog
      await test.step('Open Add Reading', async () => {
        dlg = await openAddReading(page)
      })
      await test.step('Click Show installation setup', async () => {
        await dlg.showInstallationSetup.click()
        await dlg.waitForPanel(dlg.installationPanel)
      })
      await test.step('Verify installation setup section labels appear', async () => {
        const labels = await dlg.installationPanel.locator('.el-form-item__label').allTextContents()
        for (const want of INSTALLATION_SECTION_LABELS) {
          expect(labels.map((l) => l.trim()), `安装面板缺少 ${want}`).toContain(want)
        }
      })
      await test.step('Verify calibration setup section labels appear', async () => {
        await dlg.showCalibrationSetup.click()
        await dlg.waitForPanel(dlg.calibrationPanel)
        const labels = await dlg.calibrationPanel.locator('.el-form-item__label').allTextContents()
        for (const want of CALIBRATION_SECTION_LABELS) {
          expect(labels.map((l) => l.trim()), `校准面板缺少 ${want}`).toContain(want)
        }
      })
    }
  )
})

/** Instrumentation 的 Installation Details 和 Add Reading 安装面板共有的字段 */
const INSTALLATION_FIELDS = [
  'Measurement Unit',
  'Soil Member',
  'As Built Tip Elevation',
  'Target Piezometric Elevation',
  'Avg Fill Unit Weight',
  'Avg Insitu Unit Weight'
]

/** Instrumentation 的 Sensor Details 和 Add Reading 校准面板共有的字段 */
const SENSOR_FIELDS = [
  'Sensor',
  'Manufacture',
  'Make',
  'Model',
  'Linear Calibration Factor, C.F.',
  'Temperature Correction Factor, Tk',
  'Polynomial Gauge Factor C',
  'Fluid Density(KN/m³)',
  'Calibration Type',
  'Calibration Calculation Method'
]

const INSTALLATION_SECTION_LABELS = [
  'Measurement Unit',
  'As Built Northing',
  'As Built Easting',
  'Original Ground Elevation',
  'Current Ground Elevation'
]

const CALIBRATION_SECTION_LABELS = [
  'Manufacture',
  'Model',
  'Linear Calibration Factor, C.F.',
  'Calibration Type',
  'Calibration Calculation Method'
]
