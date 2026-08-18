# Hisingen Website Design System

This is the design system for the Hisingen **website**, not the native macOS application. It describes how the website presents a small, technical product with clarity and restraint.

## Direction

Hisingen is a Swedish product site for an independent native Mac utility. The visual language is built from a deep blue-green product shell, a single ochre signal colour, warm paper surfaces, technical labels, real product screens and plainspoken copy. It should feel considered rather than luxurious, and technical rather than futuristic.

Polestar influence means architectural composition, typographic confidence, negative space and product-first imagery. Volvo influence means readable hierarchy, calm information design, clear actions and inclusive responsive behavior. Neither brand supplies Hisingen's colours, logos, typography or navigation patterns. Polestar and Volvo are supported ecosystems, not the site's visual owners.

## Grid and layout

- Content container: `min(1200px, calc(100% - 48px))`.
- Wide media may use the full container; prose is capped at `62ch`.
- Desktop gutters: 24px minimum, 48px preferred at large widths.
- Mobile gutters: 20px at widths below 600px.
- Narrative sections use a 5/7 or 7/5 split. Do not center every section.
- Breakpoints: 600px mobile, 900px tablet, 1200px desktop.
- Use alignment, rules and whitespace before adding a panel or card.

## Spacing

Use the finite scale: `4, 8, 12, 16, 24, 32, 48, 64, 96, 128` pixels.

- Inline/component spacing: 4–16px.
- Control and list internals: 12–24px.
- Section spacing: 64–96px.
- Major narrative breaks: 96–128px.

## Typography

The site uses the system sans stack so it feels natural on macOS, loads no remote font, and remains fast and legally uncomplicated. `SF Pro Display` is used when available, with Segoe UI and Arial fallbacks. Monospace labels use the system mono stack for technical context.

- Display: `clamp(3rem, 6vw, 6.6rem)`, tight leading; use sparingly for the hero.
- H1: `clamp(3.25rem, 6.2vw, 6.6rem)`, 0.96 leading.
- H2: `clamp(2.5rem, 4.2vw, 4.6rem)`, 0.98 leading.
- H3: 1.25–1.6rem, 1.1 leading.
- Body large: 1.1rem, 1.55 leading.
- Body: 1rem, 1.6 leading; prose stays near 60–70 characters.
- Small: 0.875rem; label/caption: 0.6875rem in uppercase mono.
- Buttons: 0.875rem, semibold.
- Use tabular numerals for metrics and metadata.

## Colour

Light mode uses porcelain and mineral mist rather than pure white. The primary product shell is deep slate, with a soft sage Hisingen signal colour used for action and state. Dark mode uses layered blue-slate surfaces rather than black. The accent is Hisingen's own mineral signal colour; it is not a Polestar or Volvo brand colour.

```css
--surface-primary: #f5f7f4;
--surface-secondary: #e7ece9;
--surface-raised: #fcfdfb;
--text-primary: #1d2a2e;
--text-secondary: #617074;
--text-muted: #879391;
--border-subtle: #cbd5d2;
--border-strong: #617074;
--accent: #b7cbbd;
--accent-hover: #456b5a;
```

Dark equivalents are `#111a1e`, `#1d2b30`, `#eef4f0`, `#eaf1ed`, `#a9b9b5`, `#3b4c4e`, and `#bcd5c5`. Semantic states use green, amber, red and blue only when communicating state, never as decoration.

## Controls

Primary buttons are deep slate with a soft sage hover state. Secondary actions are text links with an underline. Controls have a minimum 44px target, a visible `:focus-visible` ring and a restrained 2px radius. Full pills are reserved for real status indicators. Links remain identifiable without colour alone.

## Cards and radii

Cards are reserved for an independent object, such as a download block or a capability state. A product screenshot is not automatically placed in a card. Default radii are 2px and 8px; 999px is reserved for status chips. Avoid nested cards and glass effects.

## Imagery

Real Hisingen screens are the primary visual language. Screenshots are sharp, consistently cropped, labelled by nearby text and allowed to breathe. Do not add fake browser chrome, decorative device frames, glow, gradients or oversized rounded masks. Below-the-fold images are lazy-loaded; the hero image is eager and has dimensions to prevent layout shift.

Vehicle imagery, when added, should identify a supported ecosystem without turning the page into a manufacturer campaign. Manufacturer logos are not decorative ornaments.

## Capability and trust UI

Use plain-language states: Supported, Vehicle dependent, Region dependent, Unavailable and Experimental. Always explain what the state means. Technical uncertainty is a trust feature, not a defect to hide. Authentication, Keychain storage, direct provider connections, optional location and the independent status belong near the decision to download.

## Motion

Motion communicates state or provides small interaction feedback only. Use short opacity/transform transitions for navigation and buttons. No scroll hijacking, parallax, pulsing CTAs or reveal animation on every section. Disable non-essential motion under `prefers-reduced-motion: reduce`.

## Responsive behavior

Mobile is a composed reading order, not a squeezed desktop. The header becomes a full-width disclosure menu with large links. Hero actions stack only when needed. Screenshot pairs become a deliberate sequence, not an undifferentiated card list. Tables remain scrollable with a visible label. Text stays readable at 200% zoom and no content depends on hover.

## Copy tone

Use direct, specific language: “Check battery, range and charging from the menu bar.” Avoid inflated claims and words such as “seamlessly”, “next-generation”, “unlock”, “transformative” and “powerful”. State limitations, provider differences and independence plainly.

## Component decisions

- **KEEP:** skip link, semantic sections, real screenshots, support table, native details FAQ, static Pages architecture.
- **REFINE:** header, theme control, buttons, metadata row, screenshot captions, footer and focus treatment.
- **REDESIGN:** hero hierarchy, provider presentation, capability explanation and install path.
- **REMOVE:** decorative screenshot frames, redundant provider card treatment, excessive shadows, oversized closing type and any decorative badge that does not convey state.

## Anti-patterns

Do not use a card when spacing or a rule groups content adequately. Do not use a pill for ordinary text, navigation or headings. Do not use glass when it lowers contrast or exists only as decoration. Do not animate when no state or hierarchy changes. Do not add a three-column feature grid, fake metric, testimonial, gradient blob or manufacturer-branded theme without a real product reason.

## Correct / incorrect

**Correct:** a large, sharp menu-bar screenshot next to one sentence explaining what it shows; a thin rule separating supported model groups; a status label followed by its limitation.

**Incorrect:** three rounded feature cards with generic icons; a screenshot inside a fake laptop with a glow; a “Supported” pill with no model or capability context; a giant headline that does not mention macOS, vehicles or Hisingen.
