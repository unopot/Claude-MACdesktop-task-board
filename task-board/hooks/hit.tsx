import type { ClientModule } from 'claude-code'

// 透明点击层：什么都不画，只把左键点击转成 post({ a })，交给 register.tsx 的 ui.message 钩子。
// 代替原来盖在上面的透明 Button：没有按钮自带的反色高亮，也不会因为标签过长显示“…”。
// 悬停效果由外层带 key 的 Box 的 hover 属性负责（扁平的浅色边框 / 底色）。

/** a = 动作；t = 随动作带上的文字（建议的全文）；down = 按下就触发（不等松开） */
type HitProps = { a: string; t?: string; down?: boolean }

const Hit: ClientModule<HitProps> = (props, surface) => {
  // 每次画都重新登记（后登记的替换先登记的）：同一个 key 的点击层会跨重画保留，
  // 只在第一次登记的话，props 变了以后点下去发的还是旧动作
  // down：按下那一刻就触发。点下去时输入框失焦、上面这块跟着挪一行的话，松开时已经不在原处了，
  // 等松开才算会丢；按下就算则不受影响
  surface.onPointer(ev => {
    if (ev.button === 'left' && ev.type === (props.down ? 'down' : 'up')) surface.post({ a: props.a, t: props.t ?? null })
  })
  const { Box } = surface.elements
  return <Box width="100%" height="100%" />
}

export default Hit
