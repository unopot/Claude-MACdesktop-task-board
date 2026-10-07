import { expect, test } from 'claude-code/testing'

import { clock, dur, elapsed, freshest, isHidden, limitNow, mainLine, modelName, percent, resetIn, ringSvg, segSvg, splitStage, stagesOf, stepLines, subsByStep } from '../hooks/plan'

test('阶段：按 “阶段名: 步骤名” 分组，没前缀的跟上一个阶段，全无前缀 = 一个阶段', async () => {
  const g = stagesOf([
    { t: 'Survey: Read doors', s: 'completed', sec: 130 },
    { t: 'Survey：Probe schema', s: 'completed', sec: 330 },
    { t: 'Renumber: Set prefix', s: 'completed', sec: 192 },
    { t: 'Renumber 14 doors', s: 'in_progress', sec: 72 },
    { t: 'Export: A-201', s: 'pending', sec: -1 },
  ])
  expect(g.map(x => [x.name, x.done, x.total, x.state, x.sec])).toEqual([
    ['Survey', 2, 2, 'done', 460],
    ['Renumber', 1, 2, 'current', 264],
    ['Export', 0, 1, 'todo', 0],
  ])
  expect(g[1]?.steps.map(x => x.t)).toEqual(['Set prefix', 'Renumber 14 doors'])
  expect(stagesOf([{ t: 'a', s: 'pending', sec: -1 }, { t: 'b', s: 'pending', sec: -1 }]).length).toBe(1)
  // 太长的“前缀”不算阶段
  expect(splitStage('This is a long sentence that happens to have: a colon')).toBe(null)
})

test('耗时和模型名格式', async () => {
  expect([dur(34), dur(264), dur(3720)]).toEqual(['34s', '4m 24s', '1h 02m'])
  expect([clock(724), clock(3724)]).toEqual(['12:04', '1:02:04'])
  expect(modelName('claude-haiku-4-5-20251001')).toBe('haiku 4.5')
  expect(modelName('claude-fable-5-1')).toBe('fable 5.1')
  expect(modelName('claude-opus-5-5')).toBe('opus 5.5')
})

const row = (id: string, title: string, status: 'input' | 'running' | 'done', cacheAgeSec: number, extra = {}) => ({
  id, title, link: 'claude://claude.ai/epitaxy/local_0000', project: 'x', status, ageSec: 10, cacheAgeSec, done: 0, total: 0, current: '',
  input: 50000, cacheWrite: 20000, cacheRead: 0, output: 5000, subagents: 0, subActive: 0, ...extra,
})

test('隐藏：之后没有新请求就一直隐藏；又有请求或又在跑就回来', async () => {
  const at = 1_000_000_000
  const s = row('c', 'x', 'done', 100)
  const hiddenAt = at - 100_000
  expect(isHidden({ nextSteps: true, hidden: { c: hiddenAt } }, at, s)).toBe(true)
  expect(isHidden({ nextSteps: true, hidden: { c: hiddenAt } }, at + 600_000, { ...s, cacheAgeSec: 30 })).toBe(false)
  expect(isHidden({ nextSteps: true, hidden: { c: hiddenAt } }, at, { ...s, status: 'running' })).toBe(false)
  expect(isHidden({ nextSteps: true }, at, s)).toBe(false)
})

const BAND = {
  component: 'AbovePrompt',
  props: { hasSurvey: false, isWorking: false, maxRows: 20, bodyColumns: 100, scroll: { offset: 0, bodyRows: 19 }, view: {} },
} as const

test('任务板：本会话有 Current 标记，展开明细，隐藏已完成会话', async ($, on) => {
  const at = Date.now()
  const board = {
    at, tick: 1, prefs: { nextSteps: false, hidden: { e: at - 600_000 } }, prefsPath: 'C:/x/prefs.json',
    usage: { at: at - 5000, limits: [{ kind: 'five_hour', percentUsed: 23.5, resetsAt: new Date(at + 7_980_000).toISOString() }] },
    sessions: [
      row('a', 'Revit 门编号核对', 'running', 5, {
        done: 1, total: 3, planSec: 724, turnSec: 900, subActive: 2, model: 'claude-opus-5-5', effort: 'high',
        steps: [
          { t: 'Survey: Read doors', s: 'completed', sec: 130 },
          { t: 'Renumber: Renumber 14 doors', s: 'in_progress', sec: 72 },
          { t: 'Export: A-201', s: 'pending', sec: -1 },
        ],
        subs: [
          { name: 'Explore', desc: 'door tags', model: 'claude-haiku-4-5-20251001', tool: 'Grep', sec: 34, active: true, calls: 7, step: 1 },
          { name: 'general-purpose', desc: 'schedule', model: 'claude-sonnet-5-5', effort: 'medium', tool: 'Bash', sec: 65, active: true, calls: 1 },
          { name: 'Explore', desc: 'skill notes', model: 'claude-haiku-4-5-20251001', tool: '', sec: 18, active: false, calls: 3 },
          { name: 'Explore', desc: 'old 1', model: 'claude-haiku-4-5-20251001', tool: '', sec: 9, active: false, calls: 2 },
          { name: 'Explore', desc: 'old 2', model: 'claude-haiku-4-5-20251001', tool: '', sec: 5, active: false, calls: 1 },
        ],
      }),
      row('b', '拆分明细表到各地块', 'running', 5, { turnSec: 200 }),
      row('q', '等我授权的会话', 'input', 5, { done: 2, total: 5 }),
      row('c', '最后一轮 review 台去向', 'done', 1320),
      row('e', '已隐藏的会话', 'done', 600),
    ],
  }
  on('ui.render', async ($$, e) => {
    const { Box } = $$.ui.resolve(e)
    return <Box />
  })
  on('state.get', async (_$, e, next) => {
    if (e.plugin === 'task-board' && e.key === 'board') return { value: { value: board, version: 1 } }
    if (e.plugin === 'task-board' && e.key === 'me') return { value: { value: 'b', version: 1 } }
    return next(e)
  })
  on('ui.log', async () => ({ value: undefined }))
  on('ui.toast', async () => ({ value: undefined }))
  on('fs.read', async () => ({ value: '{"nextSteps":false}' }))
  const writes: string[] = []
  on('fs.write', async (_$, e) => {
    writes.push(String((e as { text?: unknown }).text ?? JSON.stringify(e)))
    return { value: undefined }
  })

  const ui = await $.ui.mount({ plugin: 'task-board', surface: 'desktop', ...BAND })
  // 本会话（b）有 Current 标签，别的没有
  expect(await ui.find({ type: 'Text', text: /^ Current $/ })).toBeDefined()
  // 已隐藏的 e 不在任务板上，Details 旁边显示数量
  expect(await ui.find({ key: 'row-e' })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: /Details · 1 hidden/ })).toBeDefined()
  // Running 行显示总耗时
  expect(await ui.find({ type: 'Text', text: /⏱ 12:04/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^33%$/ })).toBeDefined()
  // Running 标题行右侧：账号 5 小时额度的圆环
  expect(await ui.find({ key: 'usage-ring' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^24%$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /resets in 2h 13m/ })).toBeDefined()
  // 在等我决定：有清单也显示 needs input（不是百分比）
  expect(await ui.find({ type: 'Text', text: /^needs input$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^40%$/ })).toBeUndefined()

  // 展开 a 的明细：阶段、当前步骤耗时、子代理行
  expect(await ui.find({ key: 'detail' })).toBeUndefined()
  await ui.pointer({ type: 'up', x: 1, y: 1, button: 'left', in: 'x-a' })
  expect(await ui.find({ key: 'detail' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /running 1m 12s/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /1\/3 steps · 33%/ })).toBeDefined()
  // 阶段条：名字后面跟状态；步骤表：每步一行，耗时单独一列
  expect(await ui.find({ type: 'Text', text: /^ 0% · 1m 12s$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^ ✓ 2m 10s$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^Read doors$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^2m 10s$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /haiku 4\.5 · Grep · door tags/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /✓ 18s/ })).toBeDefined()
  // 推理强度、工具调用次数、画不下的汇总成一行
  expect(await ui.find({ type: 'Text', text: /sonnet 5\.5 · medium · Bash · schedule/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^7 calls$/ })).toBeDefined()
  // 第一个子代理挂在派它的那一步（Renumber 14 doors）下面；其余不属于任何一步，列在 Main 行下面，最多 3 行
  expect(await ui.find({ type: 'Text', text: /^\+1 more agent · 1 done$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /old 2/ })).toBeUndefined()
  // Main 行：主会话的模型、推理强度、这一轮的子代理数
  expect(await ui.find({ type: 'Text', text: /^opus 5\.5 · high · 5 subagents this turn · 2 running$/ })).toBeDefined()
  // 卡片上也看得到这个会话正在用子代理
  expect(await ui.find({ type: 'Text', text: /^ · 2 agents$/ })).toBeDefined()
  await ui.pointer({ type: 'up', x: 1, y: 0, button: 'left', in: 'hit-collapse' })
  expect(await ui.find({ key: 'detail' })).toBeUndefined()

  // 没用子代理的会话：明说 no subagents this turn，而不是什么都不画
  await ui.pointer({ type: 'up', x: 1, y: 1, button: 'left', in: 'x-b' })
  expect(await ui.find({ type: 'Text', text: /no subagents this turn$/ })).toBeDefined()
  await ui.pointer({ type: 'up', x: 1, y: 0, button: 'left', in: 'hit-collapse' })

  // 隐藏 c：写开关文件的 hidden，保留原来的 nextSteps
  await ui.pointer({ type: 'up', x: 1, y: 1, button: 'left', in: 'h-c' })
  expect(writes.length).toBe(1)
  expect(writes[0]).toMatch(/"nextSteps": false/)
  expect(writes[0]).toMatch(/"c": \d+/)
  await ui.unmount()
})

test('Details 窗：三行布局，Current / Hidden 标签，点 Unhide 写回开关文件', async ($, on) => {
  const at = Date.now()
  const board = {
    at, tick: 1, prefs: { nextSteps: false, hidden: { e: at - 600_000 } }, prefsPath: 'C:/x/prefs.json',
    sessions: [row('b', '本会话', 'running', 5), row('e', '已隐藏的会话', 'done', 600)],
  }
  on('state.get', async (_$, e, next) => {
    if (e.plugin === 'task-board' && e.key === 'board') return { value: { value: board, version: 1 } }
    if (e.plugin === 'task-board' && e.key === 'me') return { value: { value: 'b', version: 1 } }
    return next(e)
  })
  on('ui.log', async () => ({ value: undefined }))
  on('ui.toast', async () => ({ value: undefined }))
  on('fs.read', async () => ({ value: '{"nextSteps":false,"hidden":{"e":1}}' }))
  const writes: string[] = []
  on('fs.write', async (_$, e) => {
    writes.push(String((e as { text?: unknown }).text ?? ''))
    return { value: undefined }
  })
  const ui = await $.ui.mount({
    plugin: 'task-board', surface: 'desktop', component: 'Pane', requestId: 'task-board',
    props: { title: 'Sessions', isFocused: false, bodyColumns: 40, placement: 'dock', scroll: { offset: 0, bodyRows: 30 }, view: {} },
  })
  expect(await ui.find({ type: 'Text', text: /^Current$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^Hidden$/ })).toBeDefined()
  await ui.pointer({ type: 'up', x: 1, y: 0, button: 'left', in: 'hit-unhide-e' })
  expect(writes.length).toBe(1)
  expect(writes[0]).not.toMatch(/"e":/)
  await ui.unmount()
})

test('进度线不做动画：阶段条按完成比例，百分比和时间跟着清单', async () => {
  const s = row('a', 'x', 'running', 5, { done: 1, total: 3, planSec: 100, turnSec: 400 })
  expect(elapsed(s)).toBe(100)
  expect(elapsed({ ...s, done: 3 })).toBe(400)
  expect(percent(1, 3)).toBe('33%')
  expect(segSvg('current', 1, 3)).toMatch(/width="33.33%"/)
  expect(segSvg('current', 1, 3)).not.toMatch(/animate/)
  expect(segSvg('done', 2, 2)).toMatch(/width="100%" height="4" rx="2" fill="#34a853"/)
})

test('用量圆环：取新的读数，过了重置时间按 0% 算，颜色随用量变', async () => {
  const now = 1_000_000_000_000
  const old = { at: now - 60_000, limits: [{ kind: 'five_hour', percentUsed: 10 }] }
  const neu = { at: now - 1_000, limits: [{ kind: 'five_hour', percentUsed: 40, resetsAt: new Date(now + 2_700_000).toISOString() }] }
  expect(freshest(old, neu)).toBe(neu)
  expect(freshest({ at: now, limits: [] }, old)).toBe(old)
  expect(limitNow(neu, 'five_hour', now)).toEqual({ pct: 40, left: 2700 })
  expect(limitNow(neu, 'five_hour', now + 3_000_000)).toEqual({ pct: 0, left: -1 })
  expect(limitNow(neu, 'seven_day', now)).toBe(null)
  expect([resetIn(2700), resetIn(7980), resetIn(20)]).toEqual(['45 min', '2h 13m', '1 min'])
  expect(ringSvg(40)).toMatch(/stroke="#b9b6ad"/)
  expect(ringSvg(85)).toMatch(/stroke="#d97757"/)
  expect(ringSvg(97)).toMatch(/stroke="#e5484d"/)
  expect(ringSvg(0)).not.toMatch(/stroke-dasharray/)
})

test('needs input 标记：弹授权框时写本会话的标记文件，答完清空', async ($, on) => {
  const board = { at: Date.now(), tick: 1, sessions: [], inputDir: 'C:/x/in' }
  on('state.get', async (_$, e, next) => {
    if (e.plugin === 'task-board' && e.key === 'board') return { value: { value: board, version: 1 } }
    if (e.plugin === 'task-board' && e.key === 'me') return { value: { value: 'b', version: 1 } }
    return next(e)
  })
  const writes: { path: string; text: string }[] = []
  on('fs.write', async (_$, e) => {
    writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('clock.now', async () => ({ value: 1_791_000_000_000 }))
  on('classic.PermissionRequest', async () => ({}))
  on('classic.ElicitationResult', async () => ({}))
  await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: { command: 'ls' } })
  expect(writes.length).toBe(1)
  expect(writes[0]?.path.replace(/\\/g, '/')).toBe('C:/x/in/b')
  expect(writes[0]?.text).toBe('1791000000000')
  await $.classic.ElicitationResult({ mcp_server_name: 'x', action: 'accept' })
  expect(writes.length).toBe(2)
  expect(writes[1]?.text).toBe('')
  // 没挂着标记时不再写
  await $.classic.ElicitationResult({ mcp_server_name: 'x', action: 'accept' })
  expect(writes.length).toBe(2)
})

test('步骤表：每个阶段只在第一行写名字；太长时先折做完的阶段，再折没开始的，当前阶段始终展开', async () => {
  const st = (stage: string, n: number, s: string) =>
    Array.from({ length: n }, (_, i) => ({ t: `${stage}: step ${i + 1}`, s, sec: s === 'pending' ? -1 : 10 }))
  const short = stagesOf([...st('Survey', 2, 'completed'), ...st('CAD', 1, 'in_progress'), ...st('Revit', 1, 'pending')])
  expect(stepLines(short).map(l => [l.stage.name, l.first, l.step?.t ?? '(folded)'])).toEqual([
    ['Survey', true, 'step 1'],
    ['Survey', false, 'step 2'],
    ['CAD', true, 'step 1'],
    ['Revit', true, 'step 1'],
  ])
  // 3 + 3 + 3 + 3 = 12 行 > 8：Survey（做完）折成一行 → 10 行，还多 → Check / Ship（没开始）也折
  const long = stagesOf([...st('Survey', 3, 'completed'), ...st('Build', 3, 'in_progress'), ...st('Check', 3, 'pending'), ...st('Ship', 3, 'pending')])
  expect(stepLines(long).map(l => (l.step ? `${l.stage.name}/${l.step.t}` : `${l.stage.name}/folded`))).toEqual([
    'Survey/folded',
    'Build/step 1',
    'Build/step 2',
    'Build/step 3',
    'Check/folded',
    'Ship/folded',
  ])
  // 只折做完的就够了：没开始的保持展开
  const mid = stagesOf([...st('Survey', 4, 'completed'), ...st('Build', 2, 'in_progress'), ...st('Check', 3, 'pending')])
  expect(stepLines(mid).filter(l => !l.step).map(l => l.stage.name)).toEqual(['Survey'])
})

test('子代理按派它的那一步分组；Main 行写出主会话的模型，没有子代理也明说', async () => {
  const sub = (name: string, step?: number, active = false) => ({ name, desc: '', model: 'claude-haiku-4-5-20251001', tool: '', sec: 5, active, step })
  const { byStep, loose } = subsByStep([sub('a', 0), sub('b', 2, true), sub('c'), sub('d', -1), sub('e', 9), sub('f', 2)], 3)
  expect([...byStep.entries()].map(([k, v]) => [k, v.map(x => x.name)])).toEqual([[0, ['a']], [2, ['b', 'f']]])
  expect(loose.map(x => x.name)).toEqual(['c', 'd', 'e'])
  expect(mainLine('claude-fable-5-1', 'high', [])).toBe('fable 5.1 · high · no subagents this turn')
  expect(mainLine('claude-opus-5-5', null, [sub('a', 0, true), sub('b')])).toBe('opus 5.5 · 2 subagents this turn · 1 running')
  expect(mainLine(null, null, [sub('a')])).toBe('1 subagent this turn')
  // 分阶段后每步还记得自己在原列表里的序号
  expect(stagesOf([{ t: 'A: x', s: 'completed', sec: 1 }, { t: 'B: y', s: 'pending', sec: -1 }]).map(g => g.steps.map(x => x.i))).toEqual([[0], [1]])
})
