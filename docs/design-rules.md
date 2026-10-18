# Design rules

Checklist copy of PLAN.md §15. Rule numbers match the plan. Apply to every web page and app screen. PR reviews check against this list, and the mechanical rules are linted (§15.5).

## 15.1 Copy

- [ ] 1. **No subtitle that restates the title.** "Alarms" does not get "Manage your alarms". A subtitle is allowed only if it carries data (e.g., "Next: 6:30 AM").
- [ ] 2. **No filler copy:** no "Welcome back!", "Let's get started!", "Here's an overview of…", "Powered by…", "Seamlessly…", "AI-powered…".
- [ ] 3. **No emoji** in UI text, buttons, empty states, notifications or toasts.
- [ ] 4. **Sentence case** for titles, buttons and labels ("Pair iPhone", not "Pair iPhone Device Now").
- [ ] 5. **Numbers before words.** Show "62 bpm", not "Your heart rate is 62 bpm".
- [ ] 6. **Units always shown** and consistent: `bpm`, `ms`, `kcal`, `%`. Regular space before the unit (`62 bpm`).
- [ ] 7. **Empty states:** one line saying what's missing and one action. Example: "No alarms" + "New alarm". No illustrations.
- [ ] 8. **Errors** say what happened and what to do, in one or two short sentences. No apology boilerplate, no stack traces.
- [ ] 9. **Estimates are labelled once** per metric (e.g., "Estimated" caption on Calories), not repeated on every number.

## 15.2 Layout and spacing

- [ ] 10. **One spacing scale everywhere:** 4, 8, 12, 16, 24, 32, 48 (px on web, pt on iOS). No other values.
- [ ] 11. **Page padding is identical on every page:**
  - web content area `24px` desktop / `16px` below `md`;
  - iOS screen horizontal padding `16pt` via a single `.pagePadding()` modifier.
  - No per-page overrides.
- [ ] 12. **Vertical rhythm:** 24 between sections, 12 between items in a section, 8 between label and value.
- [ ] 13. **One primary action per screen/page**, top-right on web, toolbar trailing on iOS. Secondary actions go in menus.
- [ ] 14. **No hero sections, banners or marketing blocks** inside the product.
- [ ] 15. **Cards only when grouping is meaningful.** No card-inside-card. On web, Lyra cards with zero radius. On iOS, default SwiftUI styling with rounded corners (Caleb, 2026-10-08; answers PLAN.md §20 Q9).
- [ ] 16. **Alignment:** numbers right-aligned in tables; metric tiles align baselines across a row.

## 15.3 Visual

- [ ] 17. **No gradients, glows, glassmorphism, drop-shadows-as-decoration**, or animated backgrounds.
- [ ] 18. **Colour only for meaning:** state (connected/disconnected), thresholds (stress band), chart series. Use Lyra/neutral tokens on web and semantic system colours on iOS.
- [ ] 19. **Typography:**
  - JetBrains Mono (Lyra default) on web.
  - iOS: SF Pro for text and SF Mono / monospaced digits for metric values.
  - Max three type sizes per screen.
- [ ] 20. **Icons only where they aid scanning** (nav, status). No decorative icons beside headings. Phosphor on web (Lyra default), SF Symbols on iOS.
- [ ] 21. **Charts:** no 3D, no gridline clutter (4 horizontal guides at most), no legends when there is one series, axes in mono, tooltips with exact values and time.
- [ ] 22. **Motion:** only for state change (200 ms or less, ease-out). Respect Reduce Motion. The live HR number does not bounce.

## 15.4 Behaviour

- [ ] 23. **Loading:** skeletons matching final layout for loads longer than 300 ms. No spinners centred on blank pages.
- [ ] 24. **Stale data is explicit:** every live value shows its age once it is older than 60 s.
- [ ] 25. **Destructive actions** need a confirmation naming the object ("Delete alarm 'Wake up'?").
- [ ] 26. **Accessibility:** WCAG AA contrast, full keyboard navigation on web, VoiceOver and Dynamic Type on iOS, tap targets of 44 pt or more.

## 15.5 Mechanical enforcement

- [ ] Web: ESLint rules (no `rounded-*`, no arbitrary spacing values like `p-[13px]`, no emoji in JSX text), Lyra CSS hash lock, Playwright and axe accessibility checks, screenshot review.
- [ ] iOS: SwiftLint custom rules (no literal padding values outside the `Spacing` enum, no emoji in string literals), snapshot screenshots reviewed per PR.
- [ ] Both: this checklist is part of the PR template (`.github/pull_request_template.md`).

## iOS exceptions (Caleb, 2026-10-08)

The iOS app uses the default SwiftUI look instead of the Lyra-style square layout:

- Rounded corners, inset grouped lists, system materials and standard controls are allowed and preferred.
- Charts may use gradient area fills, colour by category (stress bands, HR zones) and interactive selection.
- Rules 1-9 (copy), 10-13 (spacing scale, page padding, one primary action), 22-26 (motion, loading, stale data, destructive confirmations, accessibility) still apply.
- Rule 17 (no gradients or decorative shadows) does not apply to iOS chart fills and system materials.

## Web additions (Caleb, 2026-10-08)

- Icons: Phosphor icons on cards, stat tiles, status badges, empty states and navigation. Icons sit beside a label, never alone, except icon-only buttons with an aria-label.
- Semantic colour: app-level tokens in `web/src/styles/semantic.css` (never in the generated Lyra CSS): success, warning, danger, info, plus stress bands (low, moderate, high) and five HR zones, each with light and dark values that pass WCAG AA on the card background. Colour still carries meaning (state, threshold, series) and is paired with text or an icon.
