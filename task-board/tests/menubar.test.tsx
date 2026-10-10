import { expect, mock, test } from 'claude-code/testing'
import type { TestBody } from 'claude-code/testing'
import type { RenderSurface } from 'claude-code'

// 菜单栏：桌面会话启动时插件跑一次启动器（menubar.pl start ...），设置项 menuBar 关掉时跑 stop；没有界面的会话不碰它。

async function startSession($: Parameters<TestBody>[0], on: Parameters<TestBody>[1], surfaces: RenderSurface[]) {
  const runs: string[][] = []
  mock.env(on, { HOME: '/Users/u' })
  const clock = mock.clock(on, { now: 1_791_000_000_000 })
  on('fs.read', async () => ({ value: '' }))
  on('fs.exists', async () => ({ value: true }))
  on('session.surfaces', async () => ({ value: surfaces }))
  on('session.id', async () => ({ value: 'me' }))
  on('session.start', async (_$, e) => ({ cwd: e.cwd }))
  on('command.register', async (_$, e) => ({ value: { command: e.name } }))
  on('ui.log', async () => ({ value: undefined }))
  // 扫描进程：立刻结束，什么都不输出
  on('process.spawn', async function* () {
    yield* []
    return { value: { code: 0, signal: null } }
  } as never)
  on('process.run', async (_$, e) => {
    runs.push([...e.argv])
    return { value: { exitCode: 0, stdout: 'started\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  await $.session.start({ cwd: '/Users/u/w', surface: null, isInteractive: true })
  await clock.settle()
  return runs.filter(argv => argv[1]?.endsWith('/menubar.pl'))
}

test('菜单栏：桌面会话启动时拉起（缓存分钟数、共享目录、本机标签都传过去）', { options: { deviceName: 'Mini', cacheTtlMinutes: 5 } }, async ($, on) => {
  const runs = await startSession($, on, ['desktop'])
  expect(runs.length).toBe(1)
  const [perl, launcher, verb, js, scan, ttl, shared, device] = runs[0] ?? []
  expect([perl, verb, ttl, device]).toEqual(['/usr/bin/perl', 'start', '5', 'Mini'])
  expect(launcher?.replace(/\/menubar\.pl$/, '')).toBe(js?.replace(/\/menubar\.js$/, ''))
  expect(scan).toMatch(/\/scan\.pl$/)
  expect(shared).toMatch(/task-board-shared$/)
})

test('菜单栏：设置项 menuBar 关掉 = 停掉在跑的', { options: { menuBar: false } }, async ($, on) => {
  const runs = await startSession($, on, ['desktop'])
  expect(runs.map(argv => argv.slice(2))).toEqual([['stop']])
})

test('菜单栏：没有界面的会话（claude -p、定时任务）不碰它', async ($, on) => {
  const runs = await startSession($, on, [])
  expect(runs).toEqual([])
})
