# zentao-e2e —— 禅道用例 → Playwright 前端自动化 → 结果回写禅道

把禅道里已经写好的测试用例拉出来当输入，用 Playwright 驱动 Example 前端跑一遍，
再把逐步执行结果写回禅道的用例执行记录。

覆盖范围（禅道产品 3 Damon V2，被测环境 test2 / 87）：

- **UI 用例**（Playwright 开浏览器）：`[Integration] VMP-READING-*` 21 条里的 19 条，2 条跨版本对比等 Version 1 站点
- **API 用例**（直接打后端）：`【QC Alarm】SMM` module 212 里的 8 条 regular 用例

用例按**驱动方式**分目录：`tests/ui/` 开浏览器，`tests/api/` 只打接口。
两者的 fixture、耗时、稳定性预期完全不同 —— UI 会因为一个 CSS 改动飘红，API 不会。
参考数字：19 条 UI 用例 3.9 分钟，8 条 API 用例 12 秒。

## 准备

```bash
cd zentao-e2e
npm install
npx playwright install chromium
cp .env.example .env      # 填禅道口令和 test2 账号
```

`.env` 已 git-ignore，不要提交。

## 跑

```bash
npm test              # 全部：先 api 再 ui（必须分两次，见下）
npm run test:api      # 只跑接口用例（12 秒）
npm run test:ui       # 只跑界面用例（3.9 分钟）
npx playwright test --project=ui -g VMP-READING-004   # 只跑一条
npx playwright show-report
```

**为什么 `npm test` 是两次独立调用**：后端同一个账号只保留一个有效 token，
`tests/api` 的登录会把 `tests/ui` 存下来的浏览器会话挤掉。放在一次调用里跑，
UI 用例会在中途集体 401 掉线。两次调用各自登录、各写一份报告到 `reports/`，
`push-results.mjs` 会把两份都读进来。

## 导出禅道用例

```bash
node scripts/export-cases.mjs                          # 全量列表 → cases/product-3.{json,md}
node scripts/export-cases.mjs --steps --auto           # 只导 auto=auto 的，带步骤明细
node scripts/export-cases.mjs --steps --filter "QC Alarm"
```

`cases/product-3.md` 按用例标题里的 `【路由】` 前缀分组（86 组），
挑下一批要自动化的模块时看这个文件。产物已 git-ignore。

## 回写结果

```bash
npx playwright test
node scripts/push-results.mjs                    # 干跑，只打印
node scripts/push-results.mjs --write            # 真写
node scripts/push-results.mjs --write --testtask 12   # 挂到某个测试单下
```

映射规则：

- `test()` 上的 `annotation: { type: 'zentao', description: '<用例数字ID>' }` 决定写到哪条用例
- **顶层 `test.step()` 的顺序 == 禅道用例步骤的顺序**，逐步写 pass/fail
- 失败时：出错那步记 `fail`（把断言消息前三行写进「实际情况」），之前的 `pass`，之后的 `blocked`
- 脚本步数少于用例步数时，多出来的步骤记 `blocked / 脚本未覆盖`

所以**新增一条用例的自动化时，`test.step` 的个数和顺序要跟禅道用例对齐**，
否则 push 时会打印步数不一致的告警。

## 已经踩过的坑

- **后端把 JWT 和 User-Agent 绑定**：storageState 里存的 token，换一个 UA 再用就是 401。
  所以 `playwright.config.ts` 里 `setup` 项目和 `chromium` 项目必须用同一套 `devices[...]`。
  用 curl 拿着同一个 token 也会 401，不是 token 过期。
- **必须用域名访问，不能直连 `192.0.2.13:8282`**：87 上 nginx 的 `/api/` 反代挂在
  `server_name zentao.example.internal` 上，直连 web 容器端口只有静态文件，登录会一直失败。
  这里用 Chromium 的 `--host-resolver-rules=MAP zentao.example.internal 192.0.2.13`（`TERRA_HOST_MAP`），
  既走内网也不经 Cloudflare。
- **禅道用例列表里的 `id` 是 `case_3605` 这种带前缀的串**，数字 ID 在 `caseID` 字段；
  `GET /testcases/{id}` 只吃数字，传错会返回一堆 `null` 而不是报错。
- **前端没有 `data-testid`**（`src` 里那 21 处都在 vitest 的 stub 里），
  所以定位全部靠 role + accessible name，名字来自 `src/lang/en.json`，改语言包会一起动。
- **Element Plus 的几个交互坑**：
  - `el-checkbox` 的 `<input>` 是隐藏的，要点外层 `label.el-checkbox`；
  - `el-select` / `el-date-picker` 的 input 被显示层盖住，要点 `.el-select__wrapper`；
  - 选中值也渲染在 `.el-select__placeholder` 里，真正的占位符多一个 `is-transparent`，
    抓值时用 `.el-select__selected-item:not(.is-transparent)`；
  - 页面上常年挂着几个隐藏的 `.el-picker-panel`（Reading History 的 From/To），
    断言日期面板要加 `filter({ visible: true })`。
- **展开 installation / calibration 面板后，弹窗里会出现同名字段**（Ru、B Bar 等），
  读数字段一律限定在 `#readingData` 这张卡片内定位，否则严格模式命中多个元素。
- **两个展开面板里的字段是异步拉的**，刚点开只渲染出一两个。收集字段前用
  `dlg.waitForPanel()` 等数量稳定，否则会拿到半截数据（`allTextContents()` 只有一个 `Priority`）。
- **同一账号只有一个有效 token**：api 用例登录会挤掉 ui 的浏览器会话，所以两者必须分开调用
  （见上）。要在一次调用里跑完，得给 API 用例配一个单独的账号。
- **Playwright 的 `request` context 不能覆盖 `Host` 头**（会被忽略），所以 API 用例只能按域名访问，
  没法像浏览器那样用 `--host-resolver-rules` 走内网 IP。
- **baseURL 遇到以 `/` 开头的 url 会替换整个 path**：`baseURL=http://host/api` + `get('/login')`
  得到的是 `http://host/login`，nginx 会返回 405。`/api` 前缀在客户端里手工拼。
- **`expectOpen()` 不能绑死 VWP 字段**：不同仪器类型的 Add Reading 表单字段完全不同
  （`components/reading/add/readingForm/*.vue` 一种类型一个组件），通用断言只看弹窗和 Save 在不在。

## 和用例描述对不上的地方（已按实际情况调整）

- **Abnormal Condition 只存在于 Outtake Drain 表单**（`readingForm/outtakeDrain.vue`），
  VWP 的表单里根本没有这个勾选框（`add.vue` 里那段是注释掉的）。
  VMP-READING-006/007 的前置写的是 VWP 仪器，实际改用 `TERRA_INSTRUMENT_OUTTAKE`（默认 `OD_20250910_1`），
  断言对象也从 Reading (Hz)/Temperature 换成该表单的 Time N (s) / Volume N (L) 和 Average Time/Volume。
- **VMP-READING-014 要求仪器已有 Reading History**，但用例点名的那台 VWP 在 test2 上一条读数都没有
  （Last Read 是 `-`）。改用 `TERRA_INSTRUMENT_WITH_HISTORY`（默认 `DP11-58`，有 20 条）。
- **Suspicious Reading 的 Comments 校验是 ElNotification 不是表单内联错误**：
  `add.vue` 的 `saveNext()` 里发的 `commentRequired` 通知（"Comment is required."），
  表单上不会出现 `.el-form-item__error`。
- **VMP-READING-016 能比对的传感器字段只有 3 个**（Sensor / Polynomial Gauge Factor C /
  Fluid Density），这台仪器其余传感器字段是空的。脚本只比两边都有值的字段，
  一个都比不出来时会失败而不是假装通过。

## 目录

```
fixtures/terra.ts             后端 API 客户端（登录、仪器、告警条件、qcAlarmCheck）
pages/readingList.ts          Reading List 搜仪器、进 Reading History
pages/addReadingDialog.ts     Reading Data / Add Reading 弹窗的字段、按钮、展开面板
pages/instrumentation.ts      Instrumentation → Instrument Details 的子页签
pages/fields.ts               按「表单项标签 → 值」抓一块区域的所有字段，用于跨页面比对
tests/auth.setup.ts                    登录一次，存 .auth/user.json 给 ui 项目复用
tests/ui/reading/add-reading.spec.ts       8 条：Add Reading 弹窗基础行为（VWP 仪器）
tests/ui/reading/add-reading-more.spec.ts  11 条：校验、落库+清理、跨页面比对、面板标签
tests/ui/reading/add-reading-v1.spec.ts    2 条：V1/V2 对比（没配 TERRA_V1_URL 时跳过）
tests/api/qc-alarm/smm.spec.ts             8 条：SMM 的 QC Alarm 阈值规则
scripts/zentao.mjs            禅道 REST API 客户端（换 token / 列用例 / 明细 / 回写结果）
scripts/export-cases.mjs      导出用例
scripts/push-results.mjs      回写结果（跳过的用例不回写）
```

## 当前覆盖

禅道产品 3 里 `auto=auto` 的 21 条，**19 条已实现并全部通过**：

| 禅道用例 | 说明 |
|---|---|
| 1527 001 | 从菜单进 Reading List → 搜仪器 → Reading History → 打开 Add Reading |
| 1528 002 | 必填数值字段校验 |
| 1529 003 | 数值字段拒绝文本 |
| 1530 004 | Broken Temperature 联动 Temperature |
| 1531 005 | 勾 Suspicious Reading 后 Comments 变必填 |
| 1550 006 | Abnormal Condition 隐藏原始读数输入（Outtake Drain） |
| 1551 007 | Abnormal Condition 隐藏计算字段（Outtake Drain） |
| 1552 008 | Reading Time 有时间戳且能打开日期选择器 |
| 1553 009 | Read By 下拉能展开 |
| 1554 010 | Show installation setup 展开 |
| 1555 011 | Show calibration setup 展开 |
| 1556 012 | 存一条 Reading Hz 读数再删掉 |
| 1557 013 | 存一条 B Unit 读数再删掉 |
| 1558 014 | 仪器已有 Reading History 行 |
| 1559 015 | Add Reading 安装面板 == Instrumentation Installation Details |
| 1560 016 | Add Reading 校准面板 == Instrumentation Sensor Details |
| 1561 017 | 弹窗显示正确的 Instrument ID |
| 1562 018 | 展开面板后必填字段仍在且计算字段只读 |
| 1563 019 | 两个展开面板的字段标签齐全 |

剩下 2 条（1564 V1-001 / 1565 V1-002）要同时开 Version 1 站点做对比，**默认跳过**：
v1 参考机 192.0.2.32 上 80/443 都没有服务在听，直连和经 75 跳转都连不上。
配好 `TERRA_V1_URL` / `TERRA_V1_USER` / `TERRA_V1_PASSWORD` 就会跑。
脚本里 V1 侧沿用 V2 的页面对象，**没有在真实 V1 站点上验证过**，第一次开起来大概率要按实际 DOM 调整。

### QC Alarm / SMM（module 212，18 条里的 8 条）

| 禅道用例 | 说明 |
|---|---|
| 2653 | Piezo Elevation - Regular Meter 触发，断言 alarmItem / alarmType / unit |
| 2656 | Ru - Regular 触发 |
| 2659 | Piezo Elevation - Regular 三级阈值 Yellow/Orange/Red |
| 2662 | Ru - Regular 三级阈值 |
| 2667 | Piezo Elevation - 未配置条件不触发 |
| 2668 | Ru - 未配置条件不触发 |
| 2669 | Piezo Elevation - GREEN 读数不触发 |
| 2670 | Ru - GREEN 读数不触发 |

### 会写库的用例

012 / 013 会真的存一条读数再删掉，Comments 带 `AUTOTEST-<时间戳>` 标记；
`afterEach` 里还有一层兜底清理，按标记删残留行。005 只在确认勾选框真的勾上之后才点 Save
（不然会静默存进一条读数），断言失败时不会留数据。

## QC Alarm（tests/api/qc-alarm）

这批用例是**业务规则**不是界面行为 —— 步骤统一是「配阈值 → 录一条读数 → 看触发哪级告警」，
202 条合计才 304 步。用浏览器跑一条要 60～90 秒，走接口一条 1.5 秒。

关键是 `POST /v2/pm/reading/data/qcAlarmCheck`：前端点 Save 时先调它做预检，
**提交候选读数、返回会触发的告警、不落库**。所以 regular 这批用例跑完不留任何读数数据，
只有告警条件是真建真删的。

### Piezo Elevation / Ru 是算出来的，不是录入的

SMM 表单上只有一个 `Reading` 输入框，告警比的两个参数由后端按安装参数算
（`SmmCalculationStrategy`，KPA 制）：

```
piezoElevation = asBuiltTipElevation + reading / 9.81
ru             = reading / ((asBuiltGroundElevation - asBuiltTipElevation) * 20)
```

所以：

- **仪器必须有 `asBuiltTipElevation` 和 `asBuiltGroundElevation`**，否则计算失败、告警永远不触发
  （返回空数组，看起来像"规则没生效"其实是数据缺失）。`SMM_20250915_1` 有（tip=325 ground=350）。
- 脚本**反解**出「要得到某个 Piezo/Ru 值该录多少 reading」，而不是写死魔数。
- Piezo Elevation 的绝对值在 tip 高程附近（325+），所以阈值只能相对 tip 取。
  禅道用例里写的 `Yellow=1.0` 那种绝对值在这台仪器上不可能不触发，脚本用 `tip+5 / tip+15 / tip+25`。

### 告警条件的两个坑

- `effectiveAt` 必须给且早于当前时间，否则条件不生效、告警不触发（返回空，没有任何报错）。
- `saveOrUpdate` 的响应**不带 id**，要清理得回头 `search` 一次拿 id 再删。

### 还没做的 10 条（module 212 一共 18 条）

- **rate / difference 共 8 条**（2654/2655/2657/2658/2660/2661/2663/2664）：
  这两种类型要跟**前一条读数**比，而 `SMM_20250915_1` 没有历史读数，qcAlarmCheck 直接返回空。
  要做得先种 1～2 条读数（`POST /v2/pm/reading/data/save`）再删（`DELETE /v2/pm/reading/delete`），
  和 UI 那边 VMP-READING-012/013 是同一套「自建数据、跑完删」的路子。
- **告警邮件 2 条**（2671/2672）：要真的存读数触发告警，再查 `/pm/alarm/email/list/search`。

### 并行

现在 8 条用例共用一台 SMM 仪器，`afterEach` 会清掉它上面**所有**告警条件，所以不能并行。
要开多 worker，得做到每条用例自建仪器 —— 这也是从 8 条扩到 202 条必须做的一步，
否则不同仪器类型的用例会互相污染。

## 环境

| 项 | 值 |
|---|---|
| 被测前端 | test2（87），`http://zentao.example.internal` → 192.0.2.13 |
| 测试账号 | `tester7`（登录还要填 User Email Address，默认 `test@ops.ca`） |
| 测试数据 | VWP 仪器 `VP26-AEP Pond-BH-20260615210219670`、Outtake Drain `OD_20250910_1`、有历史读数的 `DP11-58`，分别对应 `TERRA_INSTRUMENT` / `TERRA_INSTRUMENT_OUTTAKE` / `TERRA_INSTRUMENT_WITH_HISTORY` |
| 禅道 | 83 演练实例，产品 3，账号 `e2e_test`（专用自动化账号）；换 75 现网只改 `.env` 里的 `ZENTAO_URL` |
| QC Alarm 仪器 | `SMM_20250915_1`（`TERRA_SMM_INSTRUMENT`），必须有安装参数且开跑前没有告警条件 |

`tests/auth.setup.ts` 每轮登录一次并存 storageState，其余用例复用，不重复登录。
