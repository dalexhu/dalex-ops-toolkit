import { defineConfig, devices } from '@playwright/test'
import 'dotenv/config'

export default defineConfig({
  testDir: './tests',
  timeout: 60_000,
  expect: { timeout: 10_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  // JSON 报告放在 reports/ 而不是 test-results/：后者每次跑都会被清空，
  // ui 和 api 是两次独立调用，报告放一起会被后一次删掉
  reporter: [
    ['list'],
    ['json', { outputFile: process.env.PLAYWRIGHT_JSON_OUTPUT_NAME || 'reports/results.json' }],
    ['html', { open: 'never' }]
  ],
  use: {
    baseURL: process.env.TERRA_URL,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'off',
    actionTimeout: 15_000,
    launchOptions: {
      // nginx 的 /api 反代按 server_name 匹配，必须用域名访问；这里把域名指到内网 IP
      args: process.env.TERRA_HOST_MAP ? [`--host-resolver-rules=MAP ${process.env.TERRA_HOST_MAP}`] : []
    }
  },
  projects: [
    // setup 必须和 ui 用同一套 device（同 UA）：后端把 token 和 User-Agent 绑定了，
    // UA 不一致时保存下来的 token 会被判 401
    { name: 'setup', testMatch: /auth\.setup\.ts/, use: { ...devices['Desktop Chrome'] } },
    {
      // 浏览器驱动的界面用例
      name: 'ui',
      testDir: './tests/ui',
      use: { ...devices['Desktop Chrome'], storageState: '.auth/user.json' },
      dependencies: ['setup']
    },
    {
      // 直接打后端的业务规则用例，不开浏览器，自己登录（fixtures/terra.ts）
      // 注意：QC Alarm 这批共用同一台 SMM 仪器，afterEach 会清掉它上面所有告警条件，
      // 所以不能并行。要并行得先做到每条用例自建仪器。
      name: 'api',
      testDir: './tests/api'
    }
  ]
})
