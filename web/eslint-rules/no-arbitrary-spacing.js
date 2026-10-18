import { splitTokens, utilityOf } from './tailwind.js'

const SPACING_ARBITRARY =
  /^-?(p|px|py|pt|pr|pb|pl|ps|pe|m|mx|my|mt|mr|mb|ml|ms|me|gap|gap-x|gap-y|space-x|space-y|inset|inset-x|inset-y|top|right|bottom|left|start|end)-\[[^\]]*\]$/

export default {
  meta: {
    type: 'problem',
    docs: { description: 'Forbid arbitrary Tailwind spacing values (PLAN.md §15.2 rule 10)' },
    schema: [],
    messages: {
      arbitrary: 'Use the spacing scale (4, 8, 12, 16, 24, 32, 48), not "{{ token }}" (PLAN.md §15.2).',
    },
  },
  create(context) {
    function checkText(node, text) {
      for (const token of splitTokens(text)) {
        if (SPACING_ARBITRARY.test(utilityOf(token))) {
          context.report({ node, messageId: 'arbitrary', data: { token } })
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
    }
  },
}
