import { test as setup, expect } from '@playwright/test'

const AUTH_FILE = '.auth/user.json'

setup('login', async ({ page }) => {
  await page.goto('/login')

  // 登录表单三个字段在源码里带明确的 autocomplete/type，比 label 稳
  await page.locator('input[autocomplete="username"]').fill(process.env.TERRA_USER!)
  await page.locator('input[autocomplete="current-password"]').fill(process.env.TERRA_PASSWORD!)
  const email = page.locator('input[type="email"]')
  if (await email.count()) await email.fill(process.env.TERRA_EMAIL || 'test@ops.ca')

  await page.getByRole('button', { name: /log ?in/i }).click()

  // 路由守卫要先跑完 initialization（拉 users/info + 动态菜单）才算真正登录成功，
  // 以左侧菜单渲染出来为准，别用 waitForResponse（那次请求可能在监听前就回来了）
  await expect(page).not.toHaveURL(/\/login/, { timeout: 30_000 })
  await expect(page.getByRole('menuitem', { name: 'Reading', exact: true })).toBeVisible({
    timeout: 30_000
  })
  await page.context().storageState({ path: AUTH_FILE })
})
