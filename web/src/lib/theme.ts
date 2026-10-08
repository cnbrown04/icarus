const DARK_QUERY = '(prefers-color-scheme: dark)'

function applyColorScheme(dark: boolean) {
  document.documentElement.classList.toggle('dark', dark)
}

// Mirrors the OS colour scheme onto <html class="dark">, the shadcn convention.
export function followSystemColorScheme(): () => void {
  const media = window.matchMedia(DARK_QUERY)
  const onChange = (event: MediaQueryListEvent) => applyColorScheme(event.matches)

  applyColorScheme(media.matches)
  media.addEventListener('change', onChange)
  return () => media.removeEventListener('change', onChange)
}
