# Hisingen Website Design System

This document covers the Hisingen **website only**. It does not describe native macOS application components.

## Direction

Hisingen is an independent, Swedish-made native Mac utility for supported Polestar and Volvo vehicles. The website should feel precise, calm and technically honest. Product screenshots carry the visual story; typography, rules and spacing provide the structure.

Polestar contributes architectural composition, restraint, strong alignment and product-first imagery. Volvo contributes clarity, readable hierarchy, inclusive behavior and functional simplicity. Hisingen owns the mineral-green palette, system typography, direct voice and menu-bar context. Vehicle manufacturers are supported ecosystems, never the site's visual owners.

## Grid and spacing

- Content width: `1200px` maximum.
- Wide media may fill the content width; prose is limited to roughly `55–75ch`.
- Gutters: 28px desktop, 20px below 600px, 24px at tablet widths.
- Narrative layouts use asymmetric 7/5 or 5/7 columns. Centering is reserved for focused actions.
- Breakpoints: 600px mobile, 1000px tablet, 1200px wide desktop.
- Spacing scale: `4, 8, 12, 16, 24, 32, 48, 64, 96, 128`.
- Inline spacing is 4–16px; component internals 12–24px; section spacing 86–128px.

## Typography

The site uses the macOS system stack: `-apple-system, BlinkMacSystemFont, SF Pro Display, Segoe UI, Arial, sans-serif`. No remote font is loaded, so the site is fast, legally uncomplicated and native to the audience's platform. System mono is reserved for technical labels and section numbering.

| Style | Guidance |
| --- | --- |
| Display / H1 | `clamp(3.25rem, 6vw, 6rem)`, tight leading; mention the product context |
| H2 | `clamp(2.5rem, 4.6vw, 4.5rem)`, use for narrative turns |
| H3 | 1.55–2.2rem, 1.02 leading |
| Body large | 1.1–1.15rem, 1.6 leading |
| Body | 1rem, 1.6 leading |
| Small | .75–.875rem |
| Label | .68rem mono, uppercase, letter spacing |
| Button | .84rem, bold, minimum 50px high |

Use tabular numerals when displaying vehicle metrics. Do not use oversized headlines merely to create drama.

## Colour tokens

Light mode uses warm porcelain, mineral mist and deep slate. Dark mode uses layered blue-green neutrals, not black or neon.

```css
--surface-primary: #f4f5f1;
--surface-secondary: #e7ebe5;
--surface-raised: #fbfcf9;
--text-primary: #17221f;
--text-secondary: #53645d;
--text-muted: #74827b;
--border-subtle: #ccd5ce;
--border-strong: #6c7b73;
--accent: #b9d2bd;
--accent-hover: #d2e5d4;
--success: #47765b;
--warning: #9b6c2d;
--danger: #a5514c;
--info: #587d93;
```

Dark equivalents are defined in `src/styles.css` under `data-theme` and the system preference media query. Semantic colours communicate state only. Polestar and Volvo identifiers are small neutral marks, never dominant brand colour fields.

## Controls, links and radii

- Primary: mineral-green fill for download and the main decision.
- Secondary: outlined control on dark surfaces or an underlined text link.
- Tertiary: underlined inline/standalone link with an arrow for direction.
- All controls have at least a 44px target and a visible keyboard focus ring.
- Radius scale: 2px for buttons and screenshot frames, 8px only for independent raised objects, full radius only for genuine status dots/chips.
- Hover changes colour or border; it does not make controls jump.
- Disabled controls must be visibly muted and retain readable text.

## Screenshots and vehicle imagery

Real Hisingen screens are the primary product evidence. Use a sharp source image, stable dimensions, meaningful alt text and a short caption. Do not add fake browser chrome, laptop frames, gradient halos, glass, or a decorative rounded container. Below-the-fold images are lazy-loaded; the hero is eager and dimensioned to prevent layout shift.

Vehicle imagery should identify a supported ecosystem only when it adds comprehension. Never use manufacturer logos as decoration, imitate a manufacturer campaign, or let vehicle photography overwhelm the software story.

## Capability and trust UI

Use plain status language: **Supported**, **Vehicle dependent**, **Region dependent**, **Unavailable**, and **Experimental**. Explain the implication next to the state. Never imply that a model name guarantees a capability. Authentication, Keychain storage, direct provider requests, optional location, no tracking and independent status belong near the download decision.

The website should represent the documented product surface: energy and fuel, charging history, openings, health and service, climate, software, optional location/weather, notifications, remote controls, multiple vehicles and macOS integration. Use the real screenshot that best proves each claim. Do not imply that Polestar and Volvo expose the same data: Polestar software information is shown where available, while Volvo's public APIs do not expose an equivalent state.

## Responsive behavior

Mobile is a deliberate reading order. The full-width menu is a disclosure with large links and a clear download action. The hero stacks copy before the product screenshot. Screenshot pairs remain a visual pair where readable and switch to a vertical sequence only when necessary. Wide support tables scroll inside a labelled focusable region. No content requires hover, and the layout remains usable at 200% zoom.

## Motion and accessibility

Motion communicates state or provides short interaction feedback. There is no scroll hijacking, parallax, pulsing CTA or reveal animation on every section. `prefers-reduced-motion: reduce` disables non-essential transitions and smooth scrolling.

Use semantic landmarks, one page H1, ordered heading levels, labelled navigation, descriptive alt text, native `details` for FAQ, visible focus, sufficient contrast and keyboard-accessible menus. Accessibility overrides brand expression. Never communicate status by colour alone; the capability key uses colour plus text.

## Copy tone

Write as a technically literate builder explaining the product plainly. Prefer “Check battery, range and charging from the menu bar” over “Unlock powerful vehicle insights.” Avoid “seamlessly”, “next-generation”, “transformative”, “cutting-edge”, “elevate” and unsupported marketing claims. State limitations directly.

## Component decisions

- **KEEP:** static Pages architecture, real screenshots, semantic FAQ, support table, skip link, local theme preference.
- **REFINE:** header, metadata row, buttons, focus treatment, footer and screenshot captions.
- **REDESIGN:** hero hierarchy, product story, capability gallery, provider comparison, capability key, native macOS section, trust section and install path.
- **REMOVE:** runtime screenshot swapping, duplicate feature catalogue, redundant cards, decorative frames and unsupported “read-only by default” claims.

## Anti-patterns

Do not use a card when a rule or whitespace groups content. Do not use a pill for ordinary text, navigation or headings. Do not use glass when it reduces readability or is purely decorative. Do not animate when no state or hierarchy changes. Do not add generic three-column feature grids, fake statistics, testimonials, gradient blobs, glowing borders or manufacturer-branded themes.

**Correct:** a large screenshot beside one sentence explaining its value; a thin rule separating supported model groups; a capability state followed by its limitation.

**Incorrect:** three rounded feature cards with generic icons; a screenshot in a glowing laptop frame; a “Supported” badge with no model or capability context; a headline that never says what Hisingen is.
