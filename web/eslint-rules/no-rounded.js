import { splitTokens, utilityOf } from './tailwind.js'

const ROUNDED_UTILITY = /^rounded(-|$)/
const ARBITRARY_RADIUS = /^\[.*radius/i

function isRadiusKey(name) {
  return /^border.*radius$/i.test(name.replace(/-/g, ''))
}

function keyName(property) {
  if (property.computed) return null
  if (property.key.type === 'Identifier') return property.key.name
  if (property.key.type === 'Literal' && typeof property.key.value === 'string') return property.key.value
  return null
}

export default {
  meta: {
    type: 'problem',
    docs: { description: 'Forbid rounded corners outside components/ui (PLAN.md §13.2, §15.2)' },
    schema: [],
    messages: {
      utility: 'Rounded corners are not allowed. Lyra uses square corners (PLAN.md §15.2 rule 15).',
      inline: 'Inline border radius is not allowed. Lyra uses square corners (PLAN.md §13.2).',
    },
  },
  create(context) {
    function checkText(node, text) {
      for (const token of splitTokens(text)) {
        const utility = utilityOf(token)
        if (ROUNDED_UTILITY.test(utility) || ARBITRARY_RADIUS.test(utility)) {
          context.report({ node, messageId: 'utility' })
          return
        }
      }
    }

    return {
      Literal(node) {
        if (typeof node.value === 'string') checkText(node, node.value)
      },
      TemplateElement(node) {
        checkText(node, node.value.cooked ?? '')
      },
      Property(node) {
        const name = keyName(node)
        if (name && isRadiusKey(name)) context.report({ node, messageId: 'inline' })
      },
    }
  },
}
