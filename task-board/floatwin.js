// 浮窗：一个独立的窄长小窗口，一直摊开列出所有会话，按电脑分组（本机在上，别的电脑各一组，组标题带系统图标），点一张卡片切过去。
// 不长在会话里：看 Remote Control 的远程会话、没开任何会话时也在（桌面版 / 网页看远程会话时不画 Mod 的任务板）。
// macOS 自带的 osascript 跑它，不用编译：
//
//   osascript -l JavaScript floatwin.js <scan.pl 路径> <缓存分钟数> <共享目录或空> <本机标签>
//
// 平时由插件（hooks/register.tsx 经 menubar.pl）拉起，同一时间只留一个；Claude 桌面应用关掉 2 分钟后自己退出。
// 数据和任务板、菜单栏同源：本机没有主扫描时自己跑一份 scan.pl（--latest 每 3 秒写一次文件），读这个文件；已经有主扫描
// （scan.pl 写进来的是 {"follow": 文件}）就直接读主扫描的输出文件，10 秒没更新再重起 scan.pl。
// 窗口：浮在最上面、不抢焦点；拖标题栏挪位置，拖边缘调大小（调过以后高度固定、放不下就滚动；没调过高度跟着内容走）。
// 位置和大小记在 ~/.claude/task-board-floatwin.json。
// 关闭按钮 = 隐藏：写下标记文件 ~/.claude/task-board-floatwin.hidden 后退出，启动器看到标记就不再拉起；
// 菜单栏计数的菜单里勾上 Floating window（或者设置项 Floating window 关掉再打开）它才回来。
ObjC.import('Cocoa')

const ACTIVE_SEC = 60 * 60
const REMOTE_MAX_SEC = 10 * 60
const LIVE_MAX = 8 // 每台电脑最多列这么多在跑的
const DONE_MAX = 4 // 每台电脑最多列这么多做完的
const ORDER = { input: 0, running: 1, waiting: 2, done: 3, idle: 4 }
const HEX = { input: '#f5b324', running: '#3b82f6', waiting: '#7cc4f5', done: '#34a853', idle: '#8b8f98' }
const BRIDGE_ID = /^(cse|session)_[A-Za-z0-9_-]+$/
const LOCAL_LINK = /^claude:\/\/claude\.ai\/epitaxy\/local_[0-9a-f-]+$/
const CLAUDE_APP = 'com.anthropic.claudefordesktop'
const APP_GONE_MS = 2 * 60 * 1000 // Claude 桌面应用关掉这么久就退出
const W_DEFAULT = 236 // 窄长：一列卡片
const W_MIN = 180
const W_MAX = 520
const H_MIN = 90
const PAD = 8
const SINK = 3 // 按下时卡片下沉几个点
const STICK_RIGHT = 1 // NSViewMinXMargin
const WIDE = 2 // NSViewWidthSizable

const isLive = s => s.status === 'input' || s.status === 'running' || s.status === 'waiting'

function color(hex, alpha) {
  const n = parseInt(hex.slice(1), 16)
  return $.NSColor.colorWithSRGBRedGreenBlueAlpha(((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255, alpha === undefined ? 1 : alpha)
}

function readText(path) {
  const s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null)
  return s.isNil() ? null : s.js
}

function writeText(path, text) {
  $(text).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)
}

/** 和 menubar.js 的 merge 一样（多带一个 os：那台电脑的系统，画组标题的图标用）。 */
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
      picked.set(s.id, { at: r.at, s: { ...s, ageSec: later(s.ageSec), cacheAgeSec: later(s.cacheAgeSec), turnSec: later(s.turnSec), msgAgeSec: later(s.msgAgeSec), device: r.device, os: r.os } })
    }
  }
  return [...own, ...[...picked.values()].map(x => x.s)]
}

/** 和 menubar.js 的 visible 一样。 */
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

function linkOf(s) {
  if (s.device !== undefined) return BRIDGE_ID.test(s.bridge || '') ? `claude://claude.ai/code/${s.bridge}` : ''
  return LOCAL_LINK.test(s.link || '') ? s.link : ''
}

/** 做完多久了：按最后一条对话消息算。 */
const doneAge = s => (s.msgAgeSec >= 0 ? s.msgAgeSec : s.ageSec)

function when(s) {
  if (isLive(s)) {
    const t = s.turnSec >= 0 ? s.turnSec : s.ageSec
    return t < 60 ? `${Math.floor(t)} s` : `${Math.floor(t / 60)} min`
  }
  const a = doneAge(s)
  return a < 60 ? 'now' : a < 3600 ? `${Math.floor(a / 60)}m ago` : `${Math.floor(a / 3600)}h ago`
}

/** 卡片上的状态字：在等我 / 进度 / 多久了。 */
function rightText(s) {
  if (s.status === 'input') return 'needs input'
  if (s.status === 'waiting') return 'waiting'
  if (s.status === 'running') return s.total > 0 ? `${s.done}/${s.total} · ${when(s)}` : when(s)
  return when(s)
}

function fiveHour(got) {
  try {
    const u = JSON.parse(got.usageText || 'null')
    const five = ((u && u.limits) || []).find(x => x.kind === 'five_hour')
    return five && typeof five.percentUsed === 'number' ? `5h usage ${Math.round(five.percentUsed)}%` : ''
  } catch (err) {
    return ''
  }
}

function run(argv) {
  const [scanPl = '', ttlMin = '60', shared = '', device = 'Mac'] = argv
  const ttlSec = Math.max(1, Number(ttlMin) || 60) * 60
  const home = $.NSHomeDirectory().js
  const latestPath = `${home}/.claude/task-board-floatwin-data.json`
  const pidPath = `${home}/.claude/task-board-floatwin.pid`
  const posPath = `${home}/.claude/task-board-floatwin.json`
  const hiddenPath = `${home}/.claude/task-board-floatwin.hidden`
  // 调试：环境变量 TASK_BOARD_FLOAT_DEBUG=<文件> 时，点卡片不真的打开链接，只把动作记进这个文件；
  // 往 <文件>.cmd 里写 "down x y" / "up x y"（内容区左上角起算的点）就当成一次鼠标按下 / 松开，"resize 宽 高" = 拖边缘调成这么大，"close" = 点关闭按钮，"move x y" = 鼠标移到窗口里这个位置（整个窗口左上角起算）
  const debugPath = ObjC.unwrap($.NSProcessInfo.processInfo.environment.objectForKey('TASK_BOARD_FLOAT_DEBUG')) || ''
  const debug = text => {
    if (debugPath !== '') writeText(debugPath, `${readText(debugPath) || ''}${text}\n`)
  }
  const myPid = String($.NSProcessInfo.processInfo.processIdentifier)
  const fm = $.NSFileManager.defaultManager
  writeText(pidPath, `${myPid}\n`)

  const app = $.NSApplication.sharedApplication
  app.setActivationPolicy($.NSApplicationActivationPolicyAccessory)

  // ── 扫描进程（和 menubar.js 一样）：父进程（本脚本）没了它每 5 秒能发现一次，自己退出 ──────────────
  const GUARD = "$SIG{ALRM} = sub { exit 0 if getppid() == 1; alarm 5 }; alarm 5; $0 = $ARGV[0]; do(shift @ARGV); die $@ if $@;"
  let scanner = null
  let scanStartedAt = 0
  let followPath = null
  const FOLLOW_STALE_MS = 10000
  function ensureScanner() {
    if (scanPl === '' || (scanner && scanner.isRunning) || followPath !== null) return
    const now = Date.now()
    if (now - scanStartedAt < 10000) return // 刚起过又退了：隔 10 秒再试
    scanStartedAt = now
    const args = ['-e', GUARD, scanPl, '--hours', '24', '--max', '12', '--latest', latestPath, '--lead-only']
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

  // 自己退出时窗口也会“关闭”一次：先记下是自己在退，别当成用户点了关闭按钮（那会留下隐藏标记）
  let closing = false
  function quit() {
    closing = true
    if (scanner && scanner.isRunning) scanner.terminate
    if ((readText(pidPath) || '').trim() === myPid) fm.removeItemAtPathError(pidPath, null)
    app.terminate(null)
  }

  // ── 数据 ───────────────────────────────────────────────
  let got = null
  let rows = []
  function load() {
    const text = readText(followPath ?? latestPath)
    if (text === null) {
      if (followPath !== null) stopFollowing()
      return
    }
    try {
      const g = JSON.parse(text)
      if (followPath === null && typeof g.follow === 'string') {
        followPath = g.follow
        return load()
      }
      if (typeof g.at !== 'number') return
      // 主扫描 10 秒没更新（它所在的会话关了）：不跟了，马上重起 scan.pl，谁先拿到锁谁当新的主扫描
      if (followPath !== null && Date.now() - g.at > FOLLOW_STALE_MS) return stopFollowing()
      got = g
      rows = visible(g, ttlSec)
    } catch (err) {
      // 正好在换文件：下一轮再读
    }
  }

  function stopFollowing() {
    followPath = null
    scanStartedAt = 0
    fm.removeItemAtPathError(latestPath, null) // 里面还是 follow 那一行，别再读到
  }

  // ── 位置和大小：窗口左上角 + 内容区的宽；高度只有用户拖过才记（没拖过 = 跟着内容走）。没记过就放主屏幕右上角 ──────────
  let left = null
  let top = null
  let W = W_DEFAULT
  let manualH = null
  try {
    const p = JSON.parse(readText(posPath) || 'null')
    if (p && typeof p.left === 'number' && typeof p.top === 'number') {
      left = p.left
      top = p.top
    }
    if (p && typeof p.width === 'number') W = Math.max(W_MIN, Math.min(W_MAX, Math.round(p.width)))
    if (p && typeof p.height === 'number') manualH = Math.max(H_MIN, Math.round(p.height))
  } catch (err) {
    // 用默认位置
  }
  if (left === null) {
    const v = $.NSScreen.mainScreen.visibleFrame
    left = v.origin.x + v.size.width - W - 24
    top = v.origin.y + v.size.height - 24
  }
  const geometry = () => JSON.stringify({ left: Math.round(left), top: Math.round(top), width: Math.round(W), ...(manualH === null ? {} : { height: Math.round(manualH) }) })
  let savedGeometry = geometry()

  // ── 窗口：小工具面板，浮在最上面，不抢焦点，所有桌面（含全屏）都在；能拖边缘调大小 ──────────
  const TITLED = 1, CLOSABLE = 2, RESIZABLE = 8, UTILITY = 16, NONACTIVATING = 128
  const panel = $.NSPanel.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(0, 0, W, 120), TITLED | CLOSABLE | RESIZABLE | UTILITY | NONACTIVATING, $.NSBackingStoreBuffered, false)
  panel.title = 'Task board'
  panel.level = 3 // NSFloatingWindowLevel
  panel.floatingPanel = true
  panel.hidesOnDeactivate = false
  panel.becomesKeyOnlyIfNeeded = true
  panel.releasedWhenClosed = false
  panel.collectionBehavior = 1 | 256 // 所有桌面 + 全屏应用上面
  panel.contentMinSize = $.NSMakeSize(W_MIN, H_MIN)
  panel.contentMaxSize = $.NSMakeSize(W_MAX, 4000)

  // 卡片的点击区：{ y0, y1（内容里从上往下的位置）, view（整张卡片）, link }
  let hits = []
  let pressed = -1
  let pressedAt = 0
  let doc = null

  function go(link) {
    if (debugPath !== '') return debug(`open ${link}`)
    if (link) $.NSWorkspace.sharedWorkspace.openURL($.NSURL.URLWithString(link))
  }

  /** 鼠标事件落在哪张卡片上（-1 = 不在卡片上）；slack = 上下多算几个点（卡片按下后挪了位置）。 */
  function hitAt(event, slack) {
    if (doc === null) return -1
    const p = doc.convertPointFromView(event.locationInWindow, $())
    if (p.x < PAD || p.x > W - PAD) return -1
    return hits.findIndex(h => p.y >= h.y0 - slack && p.y <= h.y1 + slack)
  }

  /** 按下：卡片下沉一点、变淡；松开：复原，还在这张卡片上就切过去。 */
  function press(i) {
    release()
    if (i < 0) return
    pressed = i
    pressedAt = Date.now()
    const h = hits[i]
    h.view.setFrameOrigin($.NSMakePoint(PAD, h.y0 + SINK))
    h.view.alphaValue = 0.72
    debug(`down ${i}`)
  }

  function release() {
    if (pressed < 0) return
    const h = hits[pressed]
    if (h) {
      h.view.setFrameOrigin($.NSMakePoint(PAD, h.y0))
      h.view.alphaValue = 1
    }
    pressed = -1
  }

  ObjC.registerSubclass({
    name: 'TaskBoardFloatTarget',
    methods: {
      'tick:': { types: ['void', ['id']], implementation: () => tick() },
      // 用户拖完窗口边缘、松手了（拖的过程中不重排，见 layout 里的 mask）
      'windowDidEndLiveResize:': { types: ['void', ['id']], implementation: () => applyResize() },
      // 鼠标在窗口上移动（见下面 edgeCursor）
      'mouseMoved:': { types: ['void', ['id']], implementation: event => hover(event.locationInWindow) },
      'mouseEntered:': { types: ['void', ['id']], implementation: event => hover(event.locationInWindow) },
      'mouseExited:': { types: ['void', ['id']], implementation: () => hover(null) },
      // 关闭按钮 = 隐藏：留下标记（启动器不再拉起）再退出
      'windowWillClose:': {
        types: ['void', ['id']],
        implementation: () => {
          if (closing) return // 是自己在退出，不是用户点的
          writeText(hiddenPath, '')
          debug('hide')
          quit()
        },
      },
    },
  })
  // 内容视图：y 从上往下算（内容比窗口矮时贴着上边）
  ObjC.registerSubclass({
    name: 'TaskBoardFloatFlipped',
    superclass: 'NSView',
    methods: { isFlipped: { types: ['bool', []], implementation: () => true } },
  })
  // 盖在所有卡片上面的一层：接鼠标按下 / 松开。窗口不在前台时第一下点击也接（不然要点两次）
  ObjC.registerSubclass({
    name: 'TaskBoardFloatHit',
    superclass: 'NSView',
    methods: {
      isFlipped: { types: ['bool', []], implementation: () => true },
      'acceptsFirstMouse:': { types: ['bool', ['id']], implementation: () => true },
      'mouseDown:': { types: ['void', ['id']], implementation: event => press(hitAt(event, 0)) },
      'mouseUp:': {
        types: ['void', ['id']],
        implementation: event => {
          const was = pressed
          const link = was >= 0 && hits[was] ? hits[was].link : ''
          const inside = was >= 0 && hitAt(event, SINK + 1) === was
          release()
          debug(`up ${was} ${inside ? 'inside' : 'outside'}`)
          if (inside) go(link)
        },
      },
    },
  })
  const target = $.TaskBoardFloatTarget.alloc.init
  panel.delegate = target
  const closeButton = panel.standardWindowButton(0) // NSWindowCloseButton
  if (!closeButton.isNil()) closeButton.toolTip = 'Hide this window. To show it again, tick Floating window in the menu bar counter’s menu.'

  // ── 鼠标移到窗口边缘时变成调大小的箭头 ──────────────────────────────
  // 这个窗口不抢焦点，所在的进程一直在后台；系统不让后台进程改鼠标指针，AppKit 自己的边缘指针也就不出来。
  // 所以：向窗口服务器要“后台也能改指针”（CGS 的连接属性，系统没有就算了），再自己盯着鼠标位置换指针。
  try {
    ObjC.bindFunction('CGSMainConnectionID', ['int', []])
    ObjC.bindFunction('CGSSetConnectionProperty', ['int', ['int', 'int', 'id', 'id']])
    const cid = $.CGSMainConnectionID()
    $.CGSSetConnectionProperty(cid, cid, $('SetsCursorInBackground'), $.NSNumber.numberWithBool(true))
  } catch (err) {
    // 没有这个接口：指针不变，拖边缘照样能调大小
  }
  const EDGE = 5 // 离边缘几个点以内算在边上
  const TOP = 1, LEFT = 2, BOTTOM = 4, RIGHT = 8 // NSCursorFrameResizePosition
  /** 这个位置（窗口坐标，左下角起算）该用的指针：在哪条边 / 哪个角上，0 = 不在边上。 */
  function zoneAt(p) {
    if (p === null) return 0
    const size = panel.frame.size
    if (p.x < -1 || p.y < -1 || p.x > size.width + 1 || p.y > size.height + 1) return 0
    return (p.y > size.height - EDGE ? TOP : 0) | (p.x < EDGE ? LEFT : 0) | (p.y < EDGE ? BOTTOM : 0) | (p.x > size.width - EDGE ? RIGHT : 0)
  }
  function edgeCursor(zone) {
    if (zone === 0) return $.NSCursor.arrowCursor
    // macOS 15 起有按边 / 角给指针的接口（带斜向的）；更早的系统只有左右、上下两种
    if ($.NSCursor.respondsToSelector('frameResizeCursorFromPosition:inDirections:')) return $.NSCursor.frameResizeCursorFromPositionInDirections(zone, 3)
    return zone & (LEFT | RIGHT) ? $.NSCursor.resizeLeftRightCursor : $.NSCursor.resizeUpDownCursor
  }
  let zone = 0
  function hover(p) {
    const z = zoneAt(p)
    if (z === zone) return
    zone = z
    edgeCursor(z).set
  }
  const frameView = panel.contentView.superview
  // 进出 + 移动，进程在后台也照样收（NSTrackingActiveAlways），范围跟着窗口大小变（NSTrackingInVisibleRect）
  frameView.addTrackingArea($.NSTrackingArea.alloc.initWithRectOptionsOwnerUserInfo($.NSMakeRect(0, 0, 1, 1), 0x01 | 0x02 | 0x80 | 0x200, target, $()))

  const scroll = $.NSScrollView.alloc.initWithFrame($.NSMakeRect(0, 0, W, 120))
  scroll.hasVerticalScroller = true
  scroll.autohidesScrollers = true
  scroll.drawsBackground = false
  scroll.borderType = 0
  panel.contentView = scroll

  const bold = $.NSFont.boldSystemFontOfSize(12)
  const font = $.NSFont.systemFontOfSize(12.5)
  const small = $.NSFont.systemFontOfSize(11)

  function label(text, f, c) {
    const l = $.NSTextField.labelWithString(text)
    l.font = f
    l.textColor = c
    l.lineBreakMode = $.NSLineBreakByTruncatingTail
    return l
  }

  /** 一行带颜色的字（[文字, 颜色, 字体] 一段段拼），放不下的末尾打省略号。 */
  function rich(parts) {
    const a = $.NSMutableAttributedString.alloc.init
    for (const [text, c, f] of parts) {
      const start = a.length
      a.mutableString.appendString(text)
      const r = $.NSMakeRange(start, text.length)
      a.addAttributeValueRange($.NSForegroundColorAttributeName, c, r)
      a.addAttributeValueRange($.NSFontAttributeName, f, r)
    }
    const para = $.NSMutableParagraphStyle.alloc.init
    para.lineBreakMode = $.NSLineBreakByTruncatingTail
    a.addAttributeValueRange($.NSParagraphStyleAttributeName, para, $.NSMakeRange(0, a.length))
    const l = $.NSTextField.labelWithAttributedString(a)
    l.maximumNumberOfLines = 1
    l.cell.usesSingleLineMode = true
    l.cell.lineBreakMode = $.NSLineBreakByTruncatingTail
    l.cell.truncatesLastVisibleLine = true
    return l
  }

  function box(fill, border, radius) {
    const b = $.NSBox.alloc.initWithFrame($.NSMakeRect(0, 0, 10, 10))
    b.boxType = 4 // NSBoxCustom
    b.titlePosition = 0
    b.cornerRadius = radius === undefined ? 6 : radius
    b.borderWidth = border ? 1 : 0
    if (border) b.borderColor = border
    b.fillColor = fill
    return b
  }

  /** 系统自带的符号图标（SF Symbols）；这台系统没有这个符号 = null。 */
  function symbol(name) {
    const img = $.NSImage.imageWithSystemSymbolNameAccessibilityDescription(name, name)
    if (img.isNil()) return null
    const iv = $.NSImageView.alloc.initWithFrame($.NSMakeRect(0, 0, 16, 16))
    iv.image = img.imageWithSymbolConfiguration($.NSImageSymbolConfiguration.configurationWithPointSizeWeight(13, $.NSFontWeightMedium))
    iv.contentTintColor = $.NSColor.labelColor
    return iv
  }

  /** 这台 / 那台电脑的会话各成一组：本机在最上面，别的电脑按标签排；别的电脑在线但没有要列的会话也留一组。 */
  function groups() {
    const out = [{ device: got.device || device, os: got.os || 'mac', local: true, list: rows.filter(s => s.device === undefined) }]
    const seen = new Map()
    for (const r of got.remote || []) {
      if (!r || typeof r.device !== 'string' || r.device === '' || typeof r.at !== 'number') continue
      if ((got.at - r.at) / 1000 > REMOTE_MAX_SEC) continue
      seen.set(r.device, r.os || '')
    }
    for (const s of rows) if (s.device !== undefined && !seen.has(s.device)) seen.set(s.device, s.os || '')
    for (const name of [...seen.keys()].sort()) out.push({ device: name, os: seen.get(name), local: false, list: rows.filter(s => s.device === name) })
    return out
  }

  /** 按现在的宽度把内容排成一列（y 从上往下算），返回内容的高度。 */
  function layout() {
    const IN = W - 2 * PAD // 卡片的宽度
    const view = $.TaskBoardFloatFlipped.alloc.initWithFrame($.NSMakeRect(0, 0, W, 10))
    // mask：用户拖窗口边缘的那一会儿不重排（重排一次要建几十个视图，跟不上鼠标），靠它让视图自己跟着变：
    // WIDE = 跟着变宽，STICK_RIGHT = 贴着右边，不写 = 不动；松手后再按新宽度重排一次
    const put = (parent, v, x, y, w, h, mask) => {
      v.frame = $.NSMakeRect(x, y, w, h)
      if (mask) v.autoresizingMask = mask
      parent.addSubview(v)
    }
    const fitted = l => {
      l.sizeToFit
      return Math.ceil(l.frame.size.width)
    }
    const dim = $.NSColor.secondaryLabelColor
    const faint = a => $.NSColor.labelColor.colorWithAlphaComponent(a)
    const found = []
    let y = PAD

    /** 一组的标题：电脑的图标（苹果 / Windows 四格 / 其它 = 显示器）+ 标签 + 这台是本机还是远程 + 各状态的数量。 */
    const header = g => {
      if (g.os === 'win') {
        for (const [dx, dy] of [[0, 0], [7, 0], [0, 7], [7, 7]]) put(view, box(color('#0078d4'), null, 0.5), PAD + 3 + dx, y + 2 + dy, 6, 6)
      } else {
        const icon = symbol(g.os === 'mac' ? 'apple.logo' : 'desktopcomputer')
        if (icon) put(view, icon, PAD + 1, y - 1, 17, 17)
        else put(view, label(g.os === 'mac' ? '' : '▣', bold, $.NSColor.labelColor), PAD + 2, y, 16, 17)
      }
      const count = f => g.list.filter(f).length
      const counts = [
        [count(s => s.status === 'input'), HEX.input],
        [count(s => s.status === 'running' || s.status === 'waiting'), HEX.running],
        [count(s => s.status === 'done' || s.status === 'idle'), HEX.done],
      ].filter(p => p[0] > 0)
      let cw = 0
      if (counts.length > 0) {
        const c = rich(counts.map(([n, hex], i) => [`${i ? '  ' : ''}● ${n}`, color(hex), small]))
        cw = fitted(c)
        put(view, c, W - PAD - 2 - cw, y + 1, cw, 15, STICK_RIGHT)
      }
      put(view, rich([[g.device, $.NSColor.labelColor, bold], [g.local ? '  this computer' : '  remote', dim, small]]), PAD + 24, y, Math.max(10, IN - 24 - cw - 8), 17, WIDE)
      y += 24
    }

    /** 一张卡片：自己一个视图（按下时整张下沉），里面的位置从卡片左上角起算。 */
    const row = s => {
      const live = isLive(s)
      const now = live && s.current ? String(s.current) : ''
      const h = live ? 49 : 26
      const hex = HEX[s.status] || HEX.idle
      const card = $.TaskBoardFloatFlipped.alloc.initWithFrame($.NSMakeRect(0, 0, IN, h))
      put(card, box(faint(0.05), s.status === 'input' ? color(hex, 0.9) : faint(0.1)), 0, 0, IN, h, WIDE)
      const title = () => rich([['● ', color(hex), font], [s.title || '(untitled)', $.NSColor.labelColor, font]])
      if (live) {
        // 两行：标题；状态 / 进度 + 正在做的那一步；最下面一条进度线
        put(card, title(), 8, 4, IN - 16, 18, WIDE)
        put(card, rich([[rightText(s), color(hex), small], ...(now ? [[`  ${now}`, dim, small]] : [])]), 24, 22, IN - 32, 15, WIDE)
        const bw = IN - 16
        put(card, box(faint(0.1), null, 1.5), 8, h - 9, bw, 3, WIDE)
        const frac = s.status === 'running' ? (s.total > 0 ? Math.max(0.04, Math.min(1, s.done / s.total)) : 0.04) : 1
        put(card, box(color(hex), null, 1.5), 8, h - 9, Math.max(3, Math.round(bw * frac)), 3)
      } else {
        // 一行：标题，右端是多久前做完
        const right = label(rightText(s), small, dim)
        const rw = fitted(right)
        put(card, right, IN - 8 - rw, 6, rw, 15, STICK_RIGHT)
        put(card, title(), 8, 4, Math.max(10, IN - 16 - rw - 6), 18, WIDE)
      }
      const link = linkOf(s)
      card.toolTip = `${s.title || '(untitled)'}\n${link === '' ? 'No link to switch to' : s.device !== undefined ? `Opens on ${s.device} via Remote Control` : 'Switch to this session'}`
      put(view, card, PAD, y, IN, h, WIDE)
      found.push({ y0: y, y1: y + h, view: card, link })
      y += h + 5
    }

    const note = (text, c) => {
      put(view, label(text, small, c || dim), PAD + 2, y, IN - 4, 15, WIDE)
      y += 20
    }

    if (got === null) {
      note('Waiting for data…')
    } else {
      groups().forEach((g, i) => {
        if (i > 0) {
          // 两台电脑之间一条细线
          put(view, box(faint(0.12), null, 0), PAD, y + 3, IN, 1, WIDE)
          y += 12
        }
        header(g)
        const live = g.list.filter(isLive)
        const finished = g.list.filter(s => !isLive(s)).sort((a, b) => doneAge(a) - doneAge(b))
        if (g.list.length === 0) note('No active sessions')
        live.slice(0, LIVE_MAX).forEach(row)
        finished.slice(0, DONE_MAX).forEach(row)
        const more = Math.max(0, live.length - LIVE_MAX) + Math.max(0, finished.length - DONE_MAX)
        if (more > 0) note(`+${more} more`)
      })
      y += 4
      const usage = fiveHour(got)
      if (usage) note(usage)
      const age = Math.max(0, Math.round((Date.now() - got.at) / 1000))
      if (age > 30) note(`Last update ${age < 120 ? `${age} s` : `${Math.round(age / 60)} min`} ago`, color(HEX.input))
    }
    const H = y + PAD - 6
    view.frame = $.NSMakeRect(0, 0, W, H)
    view.autoresizingMask = WIDE
    // 点击层盖在最上面
    put(view, $.TaskBoardFloatHit.alloc.initWithFrame($.NSMakeRect(0, 0, W, H)), 0, 0, W, H, WIDE)
    return { view, H, found }
  }

  /** 重排内容；fit = 顺便把窗口摆好（用户正在拖边缘时不动窗口）。 */
  function build(fit) {
    const at = scroll.contentView.bounds.origin.y
    const made = layout()
    hits = made.found
    pressed = -1
    doc = made.view
    if (fit) {
      // 高度：用户拖过就用拖的；没拖过跟着内容走，最高到屏幕能放下的
      const screen = panel.screen.isNil() ? $.NSScreen.mainScreen : panel.screen
      const maxH = Math.max(H_MIN, screen.visibleFrame.size.height - 60)
      const h = manualH === null ? Math.min(made.H, maxH) : manualH
      const fr = panel.frameRectForContentRect($.NSMakeRect(0, 0, W, h))
      sizing = true
      panel.setFrameDisplay($.NSMakeRect(left, top - fr.size.height, fr.size.width, fr.size.height), true)
      sizing = false
    }
    scroll.documentView = doc
    if (at > 0) {
      scroll.contentView.scrollToPoint($.NSMakePoint(0, Math.max(0, Math.min(at, made.H - scroll.contentView.bounds.size.height))))
      scroll.reflectScrolledClipView(scroll.contentView)
    }
  }

  /** 用户拖完窗口边缘：按新的宽度重排一次，拖出来的高度从此固定。 */
  let sizing = false
  function applyResize() {
    const size = scroll.frame.size
    W = Math.max(W_MIN, Math.min(W_MAX, Math.round(size.width)))
    manualH = Math.max(H_MIN, Math.round(size.height))
    build(false)
    drawn = signature()
  }

  /** 画面上会变的东西拼成一串：没变就不重画。 */
  function signature() {
    if (got === null) return 'none'
    const stale = Date.now() - got.at > 30000 ? Math.round((Date.now() - got.at) / 30000) : 0
    return JSON.stringify([groups().map(g => [g.device, g.os, g.list.map(s => [s.id, s.status, s.title, s.current, rightText(s), linkOf(s)])]), fiveHour(got), stale, W, manualH])
  }

  /** 调试用：把 <debug 文件>.cmd 里的 "down x y" / "up x y" 当成一次鼠标事件发给窗口（走真实的事件分发）。 */
  function debugCommand() {
    const cmdPath = `${debugPath}.cmd`
    const text = readText(cmdPath)
    if (text === null) return
    fm.removeItemAtPathError(cmdPath, null)
    const [verb, x, yy] = text.trim().split(/\s+/)
    if (verb === 'close') return panel.performClose($())
    if (verb === 'move') {
      // "move x y"：鼠标移到窗口里这个位置（整个窗口左上角起算）；记下算出来的边和系统当前指针的大小
      hover($.NSMakePoint(Number(x), panel.frame.size.height - Number(yy)))
      delay(0.2)
      const s = $.NSCursor.currentSystemCursor.image.size
      return debug(`move zone=${zone} cursor=${Math.round(s.width)}x${Math.round(s.height)}`)
    }
    if (verb === 'resize') {
      // "resize 宽 高"：把内容区改成这么大（左上角不动），再走一遍用户拖完边缘后的那段
      const fr = panel.frameRectForContentRect($.NSMakeRect(0, 0, Number(x), Number(yy)))
      sizing = true
      panel.setFrameDisplay($.NSMakeRect(left, top - fr.size.height, fr.size.width, fr.size.height), true)
      sizing = false
      applyResize()
      return debug(`resize ${W} ${manualH}`)
    }
    const kind = verb === 'down' ? 1 : verb === 'up' ? 2 : 0
    if (!kind) return
    const p = $.NSMakePoint(Number(x), scroll.frame.size.height - Number(yy))
    const ev = $.NSEvent.mouseEventWithTypeLocationModifierFlagsTimestampWindowNumberContextEventNumberClickCountPressure(kind, p, 0, 0, panel.windowNumber, $(), 0, 1, 1)
    panel.sendEvent(ev)
  }

  let drawn = ''
  let appSeenAt = Date.now()
  // ── 每 2 秒：守住扫描进程，读新数据，变了就重画；插件升级（旧版本目录没了）、被新实例顶掉、Claude 关了就退出 ──
  function tick() {
    if (scanPl !== '' && !fm.fileExistsAtPath(scanPl)) return quit()
    const owner = readText(pidPath)
    if (owner !== null && owner.trim() !== myPid) return quit()
    if (fm.fileExistsAtPath(hiddenPath)) return quit() // 在菜单栏里被隐藏了
    if ($.NSRunningApplication.runningApplicationsWithBundleIdentifier(CLAUDE_APP).count > 0) appSeenAt = Date.now()
    else if (Date.now() - appSeenAt > APP_GONE_MS) return quit()
    if (debugPath !== '') debugCommand()
    // 按着卡片、正在拖边缘时不重画（重画会把按着的卡片换掉）；按了 10 秒还没松开 = 松开事件丢了
    if (pressed >= 0 && Date.now() - pressedAt > 10000) release()
    if (pressed >= 0 || panel.inLiveResize) return
    if (drawn !== '') {
      // 被拖动 / 调过大小：记下来
      const f = panel.frame
      left = f.origin.x
      top = f.origin.y + f.size.height
      const g = geometry()
      if (g !== savedGeometry) {
        savedGeometry = g
        writeText(posPath, `${g}\n`)
      }
    }
    load()
    ensureScanner()
    const sig = signature()
    if (sig !== drawn) {
      build(true)
      drawn = sig
    }
  }

  tick()
  panel.orderFrontRegardless
  $.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(2, target, 'tick:', null, true)
  app.run
}
