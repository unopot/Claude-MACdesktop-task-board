import type { ClientModule } from 'claude-code'

// 透明点击层：什么都不画，只把左键点击转成 post({ a })，交给 register.tsx 的 ui.message 钩子。
// 代替原来盖在上面的透明 Button：没有按钮自带的反色高亮，也不会因为标签过长显示“…”。
// 悬停效果由外层带 key 的 Box 的 hover 属性负责（扁平的浅色边框 / 底色）。

type HitProps = { a: string }

const Hit: ClientModule<HitProps, boolean> = (props, surface) => {
  if (surface.state === undefined) {
    surface.onPointer(ev => {
      if (ev.type === 'up' && ev.button === 'left') surface.post({ a: props.a })
    })
    surface.setState(true)
  }
  const { Box } = surface.elements
  return <Box width="100%" height="100%" />
}

export default Hit
