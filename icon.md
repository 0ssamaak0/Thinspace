# Thinspace — icon design brief

A specification for the application icon and the menu bar icon. Written to be
executed without access to the conversations that produced it.

## Context

The app is a native macOS wrapper around the Claude, Gemini and ChatGPT web
apps. It is deliberately minimal: one shared WebView, one main window, and a
floating **Chat Bar** — a wide, shallow panel summoned by a global hotkey, which
appears over whatever you are doing and disappears again.

Positioning, and the thing the icon has to argue:

> Big AI. Very little app.

This brief supersedes the previous one, which drew the mark as a pure absence —
an achromatic split capsule whose subject was the gap itself. That concept is
not discarded; it is completed. Its tested findings are kept in
[Inherited findings](#inherited-findings-tested-kept) and its geometry survives
almost unchanged. What changes is what the gap *is*.

## The idea

A **thin space** (U+2009) is a real typographic character: the narrowest
deliberate gap in typesetting, roughly a fifth of an em. The old brief stopped
there: the icon draws an absence.

The new reading: **the gap is not empty — it is an opening.** Big AI is a light
source that lives behind the app and is never drawn. The app is two slabs of
glass in front of it. The only place the light gets out is the thin space, and
it does not quite fit: the beam overshoots the capsule, top and bottom.
**The light is bigger than the app.** That is the tagline, drawn.

One mark, three readings, all true of the product:

1. **A thin space** — the typographic gap; the name.
2. **An opening onto something enormous** — a sliver of what is behind.
3. **A text caret** — a thin bright vertical between two blocks means
   *type here*. Which is what Thinspace is: a summonable caret over your
   whole Mac.

## One composition, many inks

**The composition is identical in every appearance — only the fills change.**
This is the load-bearing rule of the execution (owner's decision, 2 Sep 2026,
choosing uniformity over per-appearance geometry): light, dark, tinted and
clear all show the same capsule, the same overshooting caret, the same soak and
spill of glow. What varies is what the beam is printed in:

- **By day the beam prints as ink** — cool graphite on paper, its glow a faint
  slate wash.
- **By night it shows as light** — warm white, blooming through the glass.
- **In tinted modes it is white**, riding the system's accent ramp.

The same duality the product has: the Chat Bar over a bright desktop at noon,
the Chat Bar over a dark screen at midnight. Same bar; different light. The app
icon is also, deliberately, the menu bar mark writ large: the same split
capsule and caret, given the overshoot and glow the 18 px template cannot
afford.

## The mark: a split capsule and a caret

One shallow horizontal capsule, split by a vertical cut, with a caret in the
cut. Short piece left, longer piece right.

**The asymmetry is load-bearing.** Two equal halves read as a pause button.
Short-plus-long avoids that, and carries a second meaning: a small input
becoming a longer answer.

As built (all in the 1024 pt canvas; `scripts/generate_icon_layers.py` is the
executable source of these numbers):

| | value |
|---|---|
| canvas | 1024 × 1024 pt |
| capsule | 704 × 224 pt, centred — 3.14:1, the Chat Bar's real proportions |
| corner radius | fully rounded (112 pt) |
| split position | 33% along the capsule's length |
| gap width | 40 pt (5.7% — survives as a gap at small sizes, not a hairline) |
| caret | 40 × 292 pt, fully rounded tips (r 20), overshooting 34 pt each side |

The cut is **perfectly vertical**. The caret overshoots in every appearance,
and the overshoot is legal only because the caret is drawn as a beam — soft
round tips, wrapped in glow, never a bare hard-edged bar (a square-ended solid
overhanging the capsule reads as a bar laid across a pill; tested).

The capsule sits centred with generous empty space around it. Do not fill the
canvas.

## Application icon

Authored at `Resources/AppIcon.icon/` — an `icon.json` manifest plus PNG layers
under `Assets/`. **The artwork is flat white-on-transparent silhouettes only** —
no baked gradients, no painted highlights. Icon Composer's Liquid Glass
renderer supplies all shading; the bloom layers are light sources drawn as soft
alpha, not painted shading. One set of silhouettes serves every appearance;
`icon.json` never swaps geometry per appearance, only fills and opacities.

**The caret must be the highest-contrast element in the frame.** If the slabs
ever out-contrast it, they become the subject and the idea inverts.

### Groups, front to back (as ordered in `icon.json`)

| group | layer | asset | role |
|---|---|---|---|
| Capsule | Slabs | `capsule.png` | two slabs with a **real void** between them, `glass: true` |
| Caret | Caret | `caret.png` | the beam — one shape in every appearance |
| Bloom | Soak | `bloom.png` | soft column of glow **clipped to the capsule's outer silhouette** — what the glass refracts |
| Bloom | Spill | `spill.png` | tall narrow fan of glow escaping past the capsule — present in every appearance |

The caret sits behind the glass so the slab edges refract it; the void lets it
through untouched. The spill is vertical and contained — light escaping through
a slot fans along the slot's axis; an omnidirectional halo reads as a rendering
artifact (tested).

### Appearance variants

| | light | dark | tinted |
|---|---|---|---|
| ground | `#DDE3ED` → `#8290AC` | `#1D2029` → `#07070B` | system |
| slabs | white glass | `#3E4450` glass | `#8C919E` glass |
| caret | ink `#2A2D36` → `#0A0B0F` | warm white `#FFF7EB` | white |
| soak | `#5D6B84` at 28% | `#FFE2B0` at 75% | white at 15% |
| spill | `#5D6B84` at 30% | `#FFD9A0` at 62% | white at 30% |

The palette is a duality, not a decoration: **cool ink by day, warm light by
night.** The warmth belongs to the light itself — lantern, not amber alert —
and is the only colour the mark ever carries. Provider colours (Claude coral,
Gemini blue, ChatGPT neutral) already tint the Chat Bar's glass rim at runtime;
they must not touch the icon, and the night warmth must stay far enough from
coral that it cannot read as Claude's.

The light ground is deliberately deeper than near-white: a white glass capsule
on a near-white ground is carried by the shadow alone and washes out below
about 32 pt (tested).

The `tinted` slot serves both tinted polarities, so its choices hedge: a white
caret and glow (strong on TintedDark, carried mostly by the overshoot and halo
on TintedLight) over mid-grey slabs that pull the capsule toward the middle of
the accent ramp. Clear renditions were checked in both polarities and need no
specialization of their own.

### Glass settings

Capsule group: `lighting: combined`, `specular: true`, `blur-material: 0.5`,
`refractivity: { strength: 0.62, depth: 0.55 }`, `shadow: neutral @ 0.55`,
translucency via `translucency-specializations` — 0.72 light, 0.62 dark (the
smoke deepens at night so the caret owns the frame).

`specular-highlight-placement` is left unset: `outside` over-brightens the rim
in dark mode, `automatic` is the default, and setting it explicitly would gate
the document on `specular-location` for no gain.

## Menu bar icon

**The menu bar is the same mark in template form.** macOS reads only the alpha
channel of a template image and tints it — colour, glow and translucency are
discarded, so the menu bar shows the composition's silhouette and nothing else.
The existing drawing already is that silhouette; this redesign changes nothing
in `MenuBarIcon.imageset`.

For the record, at 18×18 pt: capsule ~16 × 6 pt, corner radius 3 pt; short
piece ~5 pt, long piece ~9 pt; gap optically enlarged to ~2 px (scaled
proportionally it would vanish); straight vertical cut, no overshoot — at this
size an overshooting caret would read as a misdrawn cross. No enclosing
squircle, no shadow, no glow, no colour, no offset, and **never a scaled-down
app icon**.

## Optional: state through the gap

If menu bar state is wanted later, express it by changing **the gap**, never by
adding a badge — added detail destroys legibility at 18 px; modifying negative
space survives it.

- idle → gap at its narrowest
- Chat Bar open → gap widens one step
- private chat → pieces drawn hollow or dashed

The same grammar is the product's motion language, now with the light in it:
press the hotkey and the caret of light appears first, the slabs part, and the
Chat Bar unfolds out of the gap; dismissing compresses everything back into the
mark. The icon does what the app does.

## Do not

- No letters — and watch that the caret never grows serifs or ticks that turn
  it into an "I". No chat bubbles, brains, sparkles, orbs, or provider logos.
- No symmetry between the two pieces.
- No per-appearance geometry. Every appearance shows the same silhouettes;
  only fills and opacities may specialize.
- No provider hues anywhere in the mark; the only colour is the warmth of the
  night light.
- No baked gradients or painted highlights in the silhouettes; glass and the
  bloom layers do that work.
- The overshoot is fixed at 34 pt and is always wrapped in glow — a bare
  hard-edged bar past the capsule is forbidden.
- No scaled-down app icon in the menu bar; no lift, shadow, incline or
  overshoot there.

## Deliverables

**App icon** — `Resources/AppIcon.icon/`: `icon.json` plus `Assets/capsule.png`,
`caret.png`, `bloom.png`, `spill.png`, each 1024×1024.

**Layer generator** — `scripts/generate_icon_layers.py` (Pillow). The geometry
constants at its top are the normative copy of the table above. Regenerate with:

```bash
python3 scripts/generate_icon_layers.py --out /tmp/gen [--sheet /tmp/sheet.png]
```

**Assembly and validation** — via the `compose-app-icon` skill of the
`icon-composer` plugin (a self-contained `uv` project in that skill's
`scripts/` directory):

```bash
uv run python create_icon.py --output Resources/AppIcon.icon --icon icon.json \
    --asset capsule.png=/tmp/gen/capsule.png ... --force
uv run python validate_icon.py Resources/AppIcon.icon
```

**Ground truth** — the schema cannot model everything Icon Composer enforces,
and `ictool` ignores unknown keys, so always do both: validate, then render.

```bash
ICTOOL="/Applications/Icon Composer.app/Contents/Executables/ictool"
"$ICTOOL" Resources/AppIcon.icon --export-image --output-file /tmp/icon.png \
    --platform macOS --rendition Dark --width 512 --height 512 --scale 1 \
    --design-generation 27
```

Check `Default`, `Dark`, `TintedLight`, `TintedDark`, `ClearLight`, `ClearDark`,
and small sizes (64, 32) in at least Default and Dark. The uniformity rule
makes this check simple: every rendition must show the same drawing.

**Toolchain** — this is an Icon Composer **2.0** document: it declares
`features: ["refractivity"]`, uses `blur-material` (2.0 ignores the 1.x `blur`)
and whole-object `translucency-specializations`. It needs Icon Composer 2.0
(`ictool --version` → `short-bundle-version` ≥ 2.0). Never declare a `features`
entry the document does not actually use — `features` is a hard gate and Icon
Composer refuses documents declaring features it does not know.

**Menu bar icon** — `Resources/Assets.xcassets/MenuBarIcon.imageset/`, template
PNGs at 18 / 36 / 54 px with `"template-rendering-intent": "template"`,
consumed at `App/ThinspaceApp.swift:207` via `Image(Constants.menuBarIcon)` with
`.renderingMode(.template)`. Unchanged by this redesign.

## Inherited findings (tested, kept)

The craft ledger from earlier passes, so nobody re-tries these:

- **Equal halves read as a pause button** — the asymmetry stays.
- **An angled cut reads as a rendering artifact** and vanishes at 18 px.
- **A hairline lift of one piece** reads as a misalignment bug at menu bar size.
- **A hard-edged solid slice overhanging the capsule** reads as a bar laid
  across a pill — the shipped overshoot is legal only as a soft-tipped beam
  wrapped in glow.
- **An unclipped bloom** blurring past the slabs into the ground reads as an
  artifact — hence the soak is clipped to the capsule and the spill is a
  contained vertical fan.
- **A near-white light ground** lets the white capsule wash out below 32 pt —
  hence the deepened paper.
- **A flush ink caret by day was tried and superseded**: it made light, dark
  and tinted read as three different icons. Uniformity won (owner's decision);
  the day caret now overshoots like the night one and carries a slate glow.
- **No single tinted colour is strong in both tinted polarities** — the white
  caret over mid-grey slabs is the best compromise; on TintedLight the mark is
  carried by the overshoot and halo.

## Left open

Decisions deliberately not made here, for whoever executes this next:

- Whether the dark slabs want one more step of smoke once the icon is seen on
  a real Dock among loud neighbours.
- Whether TintedLight deserves a stronger treatment if Icon Composer ever
  splits the `tinted` slot into light and dark polarities.
- Whether the Chat Bar's summon animation should literally play the icon's
  motion language (caret of light first, then the panel unfolds).
- Whether the menu bar template should one day adopt a subtle overshoot at
  36/54 px only, where it has the pixels to read as intent.
