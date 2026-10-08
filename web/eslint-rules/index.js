import noArbitrarySpacing from './no-arbitrary-spacing.js'
import noEmojiJsx from './no-emoji-jsx.js'
import noRounded from './no-rounded.js'

export default {
  meta: { name: 'eslint-plugin-icarus', version: '0.0.0' },
  rules: {
    'no-arbitrary-spacing': noArbitrarySpacing,
    'no-emoji-jsx': noEmojiJsx,
    'no-rounded': noRounded,
  },
}
