import { test, expect, TerraApi, SMM, LEVEL } from '../../../fixtures/terra'

/**
 * 禅道产品 3 module 212：【QC Alarm】SMM 系列。
 *
 * 这批用例是业务规则，不是界面行为，所以直接打后端：
 *   建告警条件 → POST /v2/pm/reading/data/qcAlarmCheck 提交候选读数 → 断言触发的级别 → 删条件
 * qcAlarmCheck 是保存前的预检接口（前端点 Save 时先调它），**不落库**，
 * 所以 regular 这批用例跑完不留任何读数数据。
 *
 * Piezo Elevation 和 Ru 不是直接录入的，是后端按安装参数算出来的
 * （SmmCalculationStrategy，KPA 制）：
 *   piezoElevation = asBuiltTipElevation + reading / 9.81
 *   ru             = reading / ((asBuiltGroundElevation - asBuiltTipElevation) * 20)
 * 所以脚本反解出「要得到某个 Piezo/Ru 值该录多少 reading」，而不是写死魔数。
 */

const INSTRUMENT_TYPE = '10'
const INSTRUMENT_NAME = process.env.TERRA_SMM_INSTRUMENT || 'SMM_20250915_1'

let sn = ''
let tip = 0
let ground = 0

/** 反解：想让 Piezo Elevation 等于 target，该录入多少 reading */
const readingForPiezo = (target: number) => Number(((target - tip) * 9.81).toFixed(4))
/** 反解：想让 Ru 等于 target，该录入多少 reading */
const readingForRu = (target: number) => Number((target * (ground - tip) * 20).toFixed(4))

/** Piezo 的绝对值在 tip 高程附近（这台是 325），阈值只能相对 tip 取 */
const piezoThresholds = () => ({
  yellowThreshold: tip + 5,
  orangeThreshold: tip + 15,
  redThreshold: tip + 25
})
const ruThresholds = () => ({ yellowThreshold: 2, orangeThreshold: 5, redThreshold: 10 })

test.beforeAll(async () => {
  const api = await TerraApi.create()
  try {
    const inst = await api.findInstrumentByName(INSTRUMENT_TYPE, INSTRUMENT_NAME)
    sn = inst.sn
    const detail = await api.instrumentDetail(sn, INSTRUMENT_TYPE)
    tip = Number(detail.asBuiltTipElevation)
    ground = Number(detail.asBuiltGroundElevation)
    expect(
      Number.isFinite(tip) && Number.isFinite(ground) && ground > tip,
      `${INSTRUMENT_NAME} 缺少安装参数（tip=${detail.asBuiltTipElevation} ground=${detail.asBuiltGroundElevation}），` +
        `Piezo Elevation / Ru 算不出来，告警永远不会触发。换一台有安装数据的 SMM。`
    ).toBe(true)

    // 这台仪器是测试专用的：开跑前必须是干净的，否则别人配的条件会污染断言
    const existing = await api.listAlarmConditions(sn)
    expect(
      existing.length,
      `${INSTRUMENT_NAME} 上已经有 ${existing.length} 条告警条件，不是干净状态。` +
        `确认不是别人在用之后手工清掉，或换 TERRA_SMM_INSTRUMENT。`
    ).toBe(0)
  } finally {
    await api.dispose()
  }
})

test.afterEach(async ({ terra }) => {
  await terra.deleteAlarmConditions(sn)
})

test.describe('QC Alarm / SMM', () => {
  test(
    'QC-SMM Piezo Elevation - Regular Meter 告警',
    { annotation: { type: 'zentao', description: '2653' } },
    async ({ terra }) => {
      await test.step('录入 Piezo Elevation reading 超过 Regular Meter 阈值', async () => {
        const th = piezoThresholds()
        await terra.createAlarmCondition({
          sn,
          alarmParam: SMM.PIEZO_ELEVATION,
          alarmType: 'regular',
          criteriaUnit: 'meter',
          ...th
        })
        const rows = await terra.qcAlarmCheck(sn, INSTRUMENT_TYPE, readingForPiezo(th.yellowThreshold + 2))
        expect(rows).toHaveLength(1)
        expect(rows[0].alarmItem).toBe('Piezo Elevation')
        expect(rows[0].alarmType).toBe('Regular')
        expect(rows[0].unit).toBe('Meter')
        expect(rows[0].alarmLevel).toBeGreaterThan(0)
      })
    }
  )

  test(
    'QC-SMM Ru - Regular 告警',
    { annotation: { type: 'zentao', description: '2656' } },
    async ({ terra }) => {
      await test.step('录入 Ru reading 超过 Regular 阈值', async () => {
        const th = ruThresholds()
        await terra.createAlarmCondition({
          sn,
          alarmParam: SMM.RU,
          alarmType: 'regular',
          criteriaUnit: '',
          ...th
        })
        const rows = await terra.qcAlarmCheck(sn, INSTRUMENT_TYPE, readingForRu(th.yellowThreshold + 1))
        expect(rows).toHaveLength(1)
        expect(rows[0].alarmItem).toBe('Ru')
        expect(rows[0].alarmType).toBe('Regular')
        expect(rows[0].alarmLevel).toBeGreaterThan(0)
      })
    }
  )

  test(
    'QC-SMM Piezo Elevation - Regular Meter 三个级别阈值（Yellow/Orange/Red）',
    { annotation: { type: 'zentao', description: '2659' } },
    async ({ terra }) => {
      const th = piezoThresholds()
      await terra.createAlarmCondition({
        sn,
        alarmParam: SMM.PIEZO_ELEVATION,
        alarmType: 'regular',
        criteriaUnit: 'meter',
        ...th
      })
      const cases: Array<[string, number, number]> = [
        ['Yellow', th.yellowThreshold + 2, LEVEL.YELLOW],
        ['Orange', th.orangeThreshold + 2, LEVEL.ORANGE],
        ['Red', th.redThreshold + 2, LEVEL.RED]
      ]
      for (const [name, piezo, level] of cases) {
        await test.step(`录入 Piezo Elevation=${piezo}（超过 ${name}）`, async () => {
          const rows = await terra.qcAlarmCheck(sn, INSTRUMENT_TYPE, readingForPiezo(piezo))
          expect(rows).toHaveLength(1)
          expect(rows[0].alarmLevel, `期望 ${name}`).toBe(level)
          expect(Number(rows[0].currentValue)).toBeCloseTo(piezo, 1)
        })
      }
    }
  )

  test(
    'QC-SMM Ru - Regular 三个级别阈值（Yellow/Orange/Red）',
    { annotation: { type: 'zentao', description: '2662' } },
    async ({ terra }) => {
      const th = ruThresholds()
      await terra.createAlarmCondition({
        sn,
        alarmParam: SMM.RU,
        alarmType: 'regular',
        criteriaUnit: '',
        ...th
      })
      const cases: Array<[string, number, number]> = [
        ['Yellow', 3, LEVEL.YELLOW],
        ['Orange', 7, LEVEL.ORANGE],
        ['Red', 15, LEVEL.RED]
      ]
      for (const [name, ru, level] of cases) {
        await test.step(`录入 Ru=${ru}（超过 ${name}）`, async () => {
          const rows = await terra.qcAlarmCheck(sn, INSTRUMENT_TYPE, readingForRu(ru))
          expect(rows).toHaveLength(1)
          expect(rows[0].alarmLevel, `期望 ${name}`).toBe(level)
          expect(Number(rows[0].currentValue)).toBeCloseTo(ru, 1)
        })
      }
    }
  )

  test(
    'QC-SMM Piezo Elevation - 未配置 alarm condition 不触发',
    { annotation: { type: 'zentao', description: '2667' } },
    async ({ terra }) => {
      await test.step('录入 Piezo Elevation reading 超过常规阈值', async () => {
        // 不建任何条件
        const rows = await terra.qcAlarmCheck(sn, INSTRUMENT_TYPE, readingForPiezo(tip + 100))
        expect(rows).toHaveLength(0)
      })
    }
  )

  test(
    'QC-SMM Ru - 未配置 alarm condition 不触发',
    { annotation: { type: 'zentao', description: '2668' } },
    async ({ terra }) => {
      await test.step('录入 Ru reading 超过常规阈值', async () => {
        const rows = await terra.qcAlarmCheck(sn, INSTRUMENT_TYPE, readingForRu(50))
        expect(rows).toHaveLength(0)
      })
    }
  )

  test(
    'QC-SMM Piezo Elevation - GREEN 读数不触发告警',
    { annotation: { type: 'zentao', description: '2669' } },
    async ({ terra }) => {
      await test.step('录入未超阈值的 Piezo Elevation', async () => {
        const th = piezoThresholds()
        await terra.createAlarmCondition({
          sn,
          alarmParam: SMM.PIEZO_ELEVATION,
          alarmType: 'regular',
          criteriaUnit: 'meter',
          ...th
        })
        const rows = await terra.qcAlarmCheck(sn, INSTRUMENT_TYPE, readingForPiezo(th.yellowThreshold - 2))
        expect(rows).toHaveLength(0)
      })
    }
  )

  test(
    'QC-SMM Ru - GREEN 读数不触发告警',
    { annotation: { type: 'zentao', description: '2670' } },
    async ({ terra }) => {
      await test.step('录入未超阈值的 Ru', async () => {
        const th = ruThresholds()
        await terra.createAlarmCondition({
          sn,
          alarmParam: SMM.RU,
          alarmType: 'regular',
          criteriaUnit: '',
          ...th
        })
        const rows = await terra.qcAlarmCheck(sn, INSTRUMENT_TYPE, readingForRu(th.yellowThreshold - 1))
        expect(rows).toHaveLength(0)
      })
    }
  )
})
