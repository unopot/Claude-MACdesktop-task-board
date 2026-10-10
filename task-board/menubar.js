// 菜单栏：右上角常驻一个彩色计数（黄 = needs input，蓝 = running / waiting，绿 = done），点开是各会话，点一行切过去。
// 不长在会话里：没打开会话、开着 Remote Control 会话时也看得到。macOS 自带的 osascript 跑它，不用编译：
//
//   osascript -l JavaScript menubar.js <scan.pl 路径> <缓存分钟数> <共享目录或空> <本机标签>
//
// 平时由插件（hooks/register.tsx 经 menubar.pl）拉起，同一时间只留一个。数据和任务板同源：
// 自己跑一份 scan.pl（--latest 每 3 秒写一次文件），读这个文件；筛选、排序照 register.tsx 的 isActive / isHidden。
ObjC.import('Cocoa')

const ACTIVE_SEC = 60 * 60 // 多久没动静就不再列出（在跑 / 在等的始终列出）
const REMOTE_MAX_SEC = 10 * 60 // 别的电脑的快照超过这么久没更新 = 离线
const ROWS_MAX = 20
const ORDER = { input: 0, running: 1, waiting: 2, done: 3, idle: 4 }
const LABEL = { input: 'needs input', running: 'running', waiting: 'waiting', done: 'done', idle: 'idle' }
const HEX = { input: '#f5b324', running: '#3b82f6', waiting: '#7cc4f5', done: '#34a853', idle: '#8b8f98' }
const BRIDGE_ID = /^(cse|session)_[A-Za-z0-9_-]+$/
const LOCAL_LINK = /^claude:\/\/claude\.ai\/epitaxy\/local_[0-9a-f-]+$/

const isLive = s => s.status === 'input' || s.status === 'running' || s.status === 'waiting'

function color(hex) {
  const n = parseInt(hex.slice(1), 16)
  return $.NSColor.colorWithSRGBRedGreenBlueAlpha(((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255, 1)
}

function readText(path) {
  const s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null)
  return s.isNil() ? null : s.js
}

/** 本机的会话 + 别的电脑的快照（秒数按快照时间往后推，离线的跳过，同一会话取最新的一份），和 plan.ts 的 mergeRemote 一样。 */
function merge(got) {
  const own = got.sessions || []
  const ids = new Set(own.map(s => s.id))
  const picked = new Map()
  for (const r of got.remote || []) {
    if (!r || typeof r.device !== 'string' || r.device === '' || typeof r.at !== 'number' || !Array.isArray(r.sessions)) continue
    const d = Math.max(0, Math.round((got.at - r.at) / 1000))
    if (d > REMOTE_MAX_SEC) continue
    const later = x => (typeof x === 'number' && x >= 0 ? x + d : x)
    for (const s of r.sessions) {
      if (!s || !s.id || ids.has(s.id)) continue
      const prev = picked.get(s.id)
      if (prev && prev.at >= r.at) continue
      picked.set(s.id, { at: r.at, s: { ...s, ageSec: later(s.ageSec), cacheAgeSec: later(s.cacheAgeSec), turnSec: later(s.turnSec), device: r.device } })
    }
  }
  return [...own, ...[...picked.values()].map(x => x.s)]
}

/** 扫描结果 → 要列出的会话（已排序）：在跑 / 在等的都列；其余 1 小时内有请求且缓存没过期的才列；任务板上隐藏的不列。 */
function visible(got, ttlSec) {
  const hidden = (got.prefs && got.prefs.hidden) || {}
  const quietOf = s => (s.cacheAgeSec >= 0 ? s.cacheAgeSec : s.ageSec)
  return merge(got)
    .filter(s => {
      if (isLive(s)) return true
      const left = s.cacheAgeSec >= 0 ? ttlSec - s.cacheAgeSec : null
      if (!(quietOf(s) < ACTIVE_SEC && (left === null || left > 0))) return false
      const h = hidden[s.id]
      return h === undefined || got.at - quietOf(s) * 1000 > h + 15000
    })
    .sort((x, y) => (ORDER[x.status] ?? 9) - (ORDER[y.status] ?? 9) || x.ageSec - y.ageSec)
}

/** 点一行要打开的链接：本机的切到桌面应用里那个会话；别的电脑的走 Remote Control。 */
function linkOf(s) {
  if (s.device !== undefined) return BRIDGE_ID.test(s.bridge || '') ? `claude://claude.ai/code/${s.bridge}` : ''
  return LOCAL_LINK.test(s.link || '') ? s.link : ''
}

function when(s) {
  if (isLive(s)) {
    const t = s.turnSec >= 0 ? s.turnSec : s.ageSec
    return t < 60 ? `${Math.floor(t)} s` : `${Math.floor(t / 60)} min`
  }
  const a = s.ageSec
  return a < 60 ? 'just now' : a < 3600 ? `${Math.floor(a / 60)} min ago` : `${Math.floor(a / 3600)} h ago`
}

function run(argv) {
  const [scanPl = '', ttlMin = '60', shared = '', device = 'Mac'] = argv
  const ttlSec = Math.max(1, Number(ttlMin) || 60) * 60
  const home = $.NSHomeDirectory().js
  const latestPath = `${home}/.claude/task-board-menubar.json`
  const pidPath = `${home}/.claude/task-board-menubar.pid`
  const myPid = $.NSProcessInfo.processInfo.processIdentifier
  const fm = $.NSFileManager.defaultManager

  const app = $.NSApplication.sharedApplication
  app.setActivationPolicy($.NSApplicationActivationPolicyAccessory)

  // ── 扫描进程：父进程（本脚本）没了它每 5 秒能发现一次，自己退出 ──────────────
  const GUARD = "$SIG{ALRM} = sub { exit 0 if getppid() == 1; alarm 5 }; alarm 5; $0 = $ARGV[0]; do(shift @ARGV); die $@ if $@;"
  let scanner = null
  let scanStartedAt = 0
  function ensureScanner() {
    if (scanner && scanner.isRunning) return
    const now = Date.now()
    if (now - scanStartedAt < 10000) return // 刚起过又退了：隔 10 秒再试
    scanStartedAt = now
    const args = ['-e', GUARD, scanPl, '--hours', '24', '--max', '12', '--latest', latestPath]
    if (shared !== '') args.push('--shared', shared, '--device', device)
    const t = $.NSTask.alloc.init
    t.launchPath = '/usr/bin/perl'
    t.arguments = $(args)
    t.standardOutput = $.NSFileHandle.fileHandleWithNullDevice
    t.standardError = $.NSFileHandle.fileHandleWithNullDevice
    try {
      t.launch
      scanner = t
    } catch (err) {
      scanner = null
    }
  }

  function quit() {
    if (scanner && scanner.isRunning) scanner.terminate
    if ((readText(pidPath) || "").trim() === String(myPid)) fm.removeItemAtPathError(pidPath, null)
    app.terminate(null)
  }

  // ── 数据 ───────────────────────────────────────────────
  let got = null
  let rows = []
  function load() {
    const text = readText(latestPath)
    if (text === null) return
    try {
      const g = JSON.parse(text)
      if (typeof g.at !== 'number') return
      got = g
      rows = visible(g, ttlSec)
    } catch (err) {
      // 正好在换文件：下一轮再读
    }
  }

  // ── 菜单栏上的计数 ─────────────────────────────────────
  const item = $.NSStatusBar.systemStatusBar.statusItemWithLength($.NSVariableStatusItemLength)
  const barFont = $.NSFont.monospacedDigitSystemFontOfSizeWeight(13, $.NSFontWeightSemibold)
  function paintBar() {
    const a = $.NSMutableAttributedString.alloc.init
    const part = (text, hex) => {
      const start = a.length
      a.mutableString.appendString(text)
      a.addAttributeValueRange($.NSForegroundColorAttributeName, color(hex), $.NSMakeRange(start, text.length))
    }
    const count = f => rows.filter(f).length
    const parts = [
      [count(s => s.status === 'input'), HEX.input],
      [count(s => s.status === 'running' || s.status === 'waiting'), HEX.running],
      [count(s => s.status === 'done' || s.status === 'idle'), HEX.done],
    ].filter(p => p[0] > 0)
    if (parts.length === 0) part('●', HEX.idle)
    parts.forEach(([n, hex], i) => part(`${i ? ' ' : ''}● ${n}`, hex))
    a.addAttributeValueRange($.NSFontAttributeName, barFont, $.NSMakeRange(0, a.length))
    item.button.attributedTitle = a
  }

  // ── 下拉菜单（打开时现建）───────────────────────────────
  const rowFont = $.NSFont.menuFontOfSize(0)
  const smallFont = $.NSFont.menuFontOfSize(11)
  function rowTitle(s) {
    const a = $.NSMutableAttributedString.alloc.init
    const part = (text, c, font) => {
      const start = a.length
      a.mutableString.appendString(text)
      const r = $.NSMakeRange(start, text.length)
      a.addAttributeValueRange($.NSForegroundColorAttributeName, c, r)
      a.addAttributeValueRange($.NSFontAttributeName, font, r)
    }
    const hex = HEX[s.status] || HEX.idle
    part('● ', color(hex), rowFont)
    if (s.device !== undefined) part(`${s.device} · `, $.NSColor.secondaryLabelColor, rowFont)
    part(s.title || '(untitled)', $.NSColor.labelColor, rowFont)
    part(`   ${LABEL[s.status] || s.status}`, color(hex), smallFont)
    const progress = s.total > 0 ? ` · ${s.done}/${s.total}` : ''
    part(` · ${s.project || ''} · ${when(s)}${progress}`, $.NSColor.secondaryLabelColor, smallFont)
    return a
  }

  function header(text) {
    if ($.NSMenuItem.respondsToSelector('sectionHeaderWithTitle:')) return $.NSMenuItem.sectionHeaderWithTitle(text)
    const mi = $.NSMenuItem.alloc.initWithTitleActionKeyEquivalent(text, null, '')
    mi.enabled = false
    return mi
  }

  ObjC.registerSubclass({
    name: 'TaskBoardMenuTarget',
    methods: {
      'tick:': { types: ['void', ['id']], implementation: () => tick() },
      'go:': {
        types: ['void', ['id']],
        implementation: sender => {
          const link = sender.representedObject.js
          if (link) $.NSWorkspace.sharedWorkspace.openURL($.NSURL.URLWithString(link))
        },
      },
      'quit:': { types: ['void', ['id']], implementation: () => quit() },
      'menuNeedsUpdate:': { types: ['void', ['id']], implementation: menu => fill(menu) },
    },
  })
  const target = $.TaskBoardMenuTarget.alloc.init

  function fill(menu) {
    load()
    paintBar()
    menu.removeAllItems
    const live = rows.filter(isLive)
    const finished = rows.filter(s => !isLive(s))
    if (rows.length === 0) {
      const mi = $.NSMenuItem.alloc.initWithTitleActionKeyEquivalent(got ? 'No sessions in the last hour' : 'Reading sessions…', null, '')
      mi.enabled = false
      menu.addItem(mi)
    }
    for (const [name, list] of [['Running', live], ['Done', finished]]) {
      if (list.length === 0) continue
      menu.addItem(header(`${name} · ${list.length}`))
      for (const s of list.slice(0, ROWS_MAX)) {
        const link = linkOf(s)
        const mi = $.NSMenuItem.alloc.initWithTitleActionKeyEquivalent(s.title || '(untitled)', link ? 'go:' : null, '')
        mi.attributedTitle = rowTitle(s)
        mi.target = target
        mi.representedObject = $(link)
        mi.toolTip = link === '' ? 'No link to switch to' : s.current ? `Now: ${s.current}` : s.device !== undefined ? `Opens on ${s.device} via Remote Control` : 'Switch to this session'
        if (!link) mi.enabled = false
        menu.addItem(mi)
      }
    }
    menu.addItem($.NSMenuItem.separatorItem)
    const age = got ? Math.max(0, Math.round((Date.now() - got.at) / 1000)) : -1
    const status = $.NSMenuItem.alloc.initWithTitleActionKeyEquivalent(age < 0 ? 'Waiting for the first scan…' : age < 60 ? `Updated ${age} s ago` : `Last update ${Math.round(age / 60)} min ago — scanner stalled?`, null, '')
    status.enabled = false
    menu.addItem(status)
    const q = $.NSMenuItem.alloc.initWithTitleActionKeyEquivalent('Quit Task Board menu', 'quit:', 'q')
    q.target = target
    menu.addItem(q)
  }

  const menu = $.NSMenu.alloc.init
  menu.autoenablesItems = false
  menu.delegate = target
  item.menu = menu

  // ── 每 2 秒：守住扫描进程，读新数据，刷新计数；插件升级（旧版本目录没了）或者被新实例顶掉就退出 ──
  function tick() {
    if (scanPl === '' || !fm.fileExistsAtPath(scanPl)) return quit()
    const owner = readText(pidPath)
    if (owner !== null && owner.trim() !== String(myPid)) return quit()
    ensureScanner()
    load()
    paintBar()
  }

  tick()
  $.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(2, target, 'tick:', null, true)
  app.run
}
