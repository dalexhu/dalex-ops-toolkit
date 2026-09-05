import { Page, Locator, expect } from '@playwright/test'

/** el-form-item__label 里带必填星号，用精确文本匹配把 '* Reading (Hz)' 和 'Reading (Hz)' 分开 */
function exactText(s: string) {
  return new RegExp(`^\\s*\\*?\\s*${s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*$`)
}

/**
 * Reading Data / Add Reading 弹窗。
 * 字段名取自实际渲染出来的 accessible name（前端没有 data-testid，
 * 这些名字来自 src/lang/en.json，改语言包会一起动）。
 */
export class AddReadingDialog {
  constructor(private readonly page: Page) {}

  get root(): Locator {
    return this.page.getByRole('dialog', { name: 'Reading Data' })
  }

  /**
   * 读数表单本体（add.vue 里的 <T-Card id="readingData">）。
   * 展开 installation / calibration 面板后，弹窗里会出现同名字段（Ru、B Bar 等），
   * 所以读数字段一律在这张卡片内定位，否则严格模式会命中多个。
   */
  get form(): Locator {
    return this.root.locator('#readingData')
  }

  get instrumentIdGroup(): Locator {
    return this.root.getByRole('group', { name: 'Instrument ID' })
  }

  get readingTime(): Locator {
    return this.form.getByRole('combobox', { name: 'Reading Time' })
  }
  /** el-date-picker 的 input 同样被外层盖住，点 wrapper 才能弹出面板 */
  get readingTimeWrapper(): Locator {
    return this.readingTime.locator(
      'xpath=ancestor::div[contains(concat(" ", normalize-space(@class), " "), " el-select__wrapper ") or contains(concat(" ", normalize-space(@class), " "), " el-input__wrapper ")][1]'
    )
  }
  get datePickerPanel(): Locator {
    // 页面上还挂着 Reading History 的 From/To 两个隐藏 picker，只要可见的那个
    return this.page.locator('.el-picker-panel').filter({ visible: true })
  }

  get readBy(): Locator {
    return this.form.getByRole('combobox', { name: 'Read By' })
  }
  /** el-select 的 input 被选中项的 span 盖住，要点最外层 div.el-select 才能展开 */
  get readByWrapper(): Locator {
    return this.readBy.locator(
      'xpath=ancestor::div[contains(concat(" ", normalize-space(@class), " "), " el-select__wrapper ")][1]'
    )
  }
  get readByOptions(): Locator {
    return this.page.locator('.el-select-dropdown__item:visible')
  }

  get comments(): Locator {
    return this.form.getByRole('textbox', { name: 'Comments' })
  }
  // el-checkbox 的 <input> 是隐藏的，点不动：断言用 input，交互点外层 label
  get suspiciousReading(): Locator {
    return this.form.getByRole('checkbox', { name: /Suspicious Reading/ })
  }
  get suspiciousReadingLabel(): Locator {
    return this.form.locator('label.el-checkbox', { hasText: 'Suspicious Reading' })
  }
  get brokenTemperature(): Locator {
    return this.form.getByRole('checkbox', { name: 'Broken Temperature' })
  }
  get brokenTemperatureLabel(): Locator {
    return this.form.locator('label.el-checkbox', { hasText: 'Broken Temperature' })
  }

  /** 必填的原始读数字段 */
  get readingHz(): Locator {
    return this.form.getByRole('textbox', { name: '* Reading (Hz)' })
  }
  get readingBUnit(): Locator {
    return this.form.getByRole('textbox', { name: '* Reading (B Unit (Hz*Hz/1000))' })
  }
  get temperature(): Locator {
    return this.form.getByRole('textbox', { name: '*Temperature' })
  }
  get barometric(): Locator {
    return this.form.getByRole('textbox', { name: '*Barometric (kPa)' })
  }

  /** 由原始读数算出来的只读字段 */
  readonly calculatedFieldNames = [
    'Fill Elevation above Tip',
    'Pressure (kPa)',
    'Piezo Elevation',
    'Ru',
    'B Bar'
  ]
  calculated(name: string): Locator {
    return this.form.getByRole('textbox', { name, exact: true })
  }

  /** 展开面板：instrumentParams.vue 里两个 section，第一个是 installation，第二个是 calibration */
  get installationPanel(): Locator {
    return this.root.locator('.instrument-param-section').nth(0)
  }
  get calibrationPanel(): Locator {
    return this.root.locator('.instrument-param-section').nth(1)
  }

  /** Abnormal Condition 只在 Outtake Drain 这类表单上出现（见 readingForm/outtakeDrain.vue） */
  get abnormalCondition(): Locator {
    return this.form.getByRole('checkbox', { name: 'Abnormal Condition' })
  }
  get abnormalConditionLabel(): Locator {
    return this.form.locator('label.el-checkbox', { hasText: 'Abnormal Condition' })
  }

  /** 按表单项标签取输入框，标签是精确匹配（不带必填星号） */
  field(label: string): Locator {
    return this.form
      .locator('.el-form-item')
      .filter({ has: this.page.locator('.el-form-item__label', { hasText: exactText(label) }) })
      .locator('input')
      .first()
  }

  get notifications(): Locator {
    return this.page.locator('.el-notification')
  }

  get showInstallationSetup(): Locator {
    return this.root.getByRole('button', { name: 'Show installation setup' })
  }
  get showCalibrationSetup(): Locator {
    return this.root.getByRole('button', { name: 'Show calibration setup' })
  }
  get save(): Locator {
    return this.root.getByRole('button', { name: 'Save' })
  }
  get cancel(): Locator {
    return this.root.getByRole('button', { name: 'Cancel' })
  }

  /** el-form 的校验提示 */
  get validationMessages(): Locator {
    return this.form.locator('.el-form-item__error')
  }

  /** 通用：弹窗开了且表单渲染出来了（不同仪器类型字段不一样，别绑死具体字段） */
  async expectOpen() {
    await expect(this.root).toBeVisible()
    await expect(this.save).toBeVisible()
    await expect(this.form.locator('.el-form-item').first()).toBeVisible()
  }

  /** VWP 专用：必填的原始读数字段都在 */
  async expectVwpFields() {
    await expect(this.readingHz).toBeVisible()
    await expect(this.readingBUnit).toBeVisible()
    await expect(this.temperature).toBeVisible()
    await expect(this.barometric).toBeVisible()
  }

  /**
   * 展开面板里的字段是异步拉回来的，刚点开时可能只渲染出一两个。
   * 收集字段前先等到数量稳定，否则会拿到半截数据。
   */
  async waitForPanel(panel: Locator, min = 10) {
    await expect(panel.locator('.el-form-item').first()).toBeVisible({ timeout: 20_000 })
    await expect
      .poll(() => panel.locator('.el-form-item').count(), { timeout: 20_000 })
      .toBeGreaterThan(min)
  }

  async close() {
    if (await this.root.isVisible()) await this.cancel.click()
  }

  /**
   * el-checkbox 点了不一定生效：表单在算数值时会重渲染，点击会落到已经卸载的节点上。
   * 这里点完确认状态，不对就重试。
   */
  async setCheckbox(label: Locator, input: Locator, checked: boolean) {
    for (let i = 0; i < 3; i++) {
      if ((await input.isChecked()) === checked) return
      await label.first().click()
      try {
        await expect(input).toBeChecked({ checked, timeout: 3000 })
        return
      } catch {
        await this.page.waitForTimeout(500)
      }
    }
    await expect(input).toBeChecked({ checked })
  }
}
