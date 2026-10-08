// Tailwind class tokens, with variants (md:, hover:, !) stripped.
// Variants are separated by top-level colons; arbitrary values in [...] may contain colons.
export function splitTokens(text) {
  return text.split(/\s+/).filter(Boolean)
}

export function utilityOf(token) {
  let depth = 0
  let start = 0
  for (let i = 0; i < token.length; i++) {
    const char = token[i]
    if (char === '[') depth++
    else if (char === ']') depth--
    else if (char === ':' && depth === 0) start = i + 1
  }
  let utility = token.slice(start)
  if (utility.startsWith('!')) utility = utility.slice(1)
  if (utility.endsWith('!')) utility = utility.slice(0, -1)
  return utility
}
