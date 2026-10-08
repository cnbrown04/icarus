const EMOJI = /\p{Extended_Pictographic}/u

export default {
  meta: {
    type: 'problem',
    docs: { description: 'Forbid emoji in JSX text and string literals (PLAN.md §15.1 rule 3)' },
    schema: [],
    messages: {
      emoji: 'No emoji in UI text or strings (PLAN.md §15.1).',
    },
  },
  create(context) {
    function check(node, text) {
      if (EMOJI.test(text)) context.report({ node, messageId: 'emoji' })
    }

    return {
      JSXText(node) {
        check(node, node.value)
      },
      Literal(node) {
        if (typeof node.value === 'string') check(node, node.value)
      },
      TemplateElement(node) {
        check(node, node.value.cooked ?? '')
      },
    }
  },
}
