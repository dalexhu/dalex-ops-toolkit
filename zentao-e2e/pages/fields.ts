import { Locator } from '@playwright/test'

/**
 * 从一块区域里按「表单项标签 → 值」抓取所有字段。
 * 普通 input 取 value，el-select 取选中项的显示文本（select 的 input 是空的）。
 */
export async function collectFields(scope: Locator): Promise<Record<string, string>> {
  return scope.evaluate((root) => {
    const out: Record<string, string> = {}
    root.querySelectorAll('.el-form-item').forEach((item) => {
      // el-tabs 会把没激活的页签内容留在 DOM 里，只取可见的
      if (!(item as HTMLElement).offsetParent && getComputedStyle(item).position !== 'fixed') return
      const label = item.querySelector('.el-form-item__label')?.textContent?.trim()
      if (!label) return
      // el-select 把选中值也渲染在 .el-select__placeholder 里，真正的占位符多一个 is-transparent
      const selected = item.querySelector('.el-select__selected-item:not(.is-transparent)')
      const input = item.querySelector('input')
      const value = selected?.textContent?.trim() || (input ? (input as HTMLInputElement).value : '')
      if (value) out[label] = value
    })
    return out
  })
}

/** 只保留两边都有值的字段，用来做「A 的值应该出现在 B 里」这种比对 */
export function comparable(
  a: Record<string, string>,
  b: Record<string, string>,
  labels: string[]
): Array<[string, string, string]> {
  return labels
    .filter((l) => a[l] !== undefined && b[l] !== undefined)
    .map((l) => [l, a[l], b[l]] as [string, string, string])
}
