# Voxglass app icon handoff

> **Superseded 2026-09-30.** The "Vox pane" concept below was not used. The commissioned Parso family icon (V, Vanadium) is in `Voxglass/Resources/AppIcon.icon`, with its layers, colours and style guide in this folder (`FAMILY_README.md`, `style-guide.pdf`).

Please deliver the final icon as a native Apple Icon Composer asset for the Voxglass app. The icon should communicate a warm, human audiobook voice inside a quiet glass pane: no words, initials, book title, or periodic-table symbols.

## Build the artwork

Create a 1024 × 1024 vector canvas with these named layers and exact geometry:

1. `background.svg`: a full-bleed vertical gradient, `#241A10` at the top to `#0A0B0D` at the bottom.
2. `pane.svg`: a rounded rectangle at `x=192, y=192, width=640, height=640, corner radius=148`, rotated `-8°` around `(512, 512)`, filled `#FFFFFF` at 18% opacity.
3. `mark.svg`: seven vertical rounded bars, each 56 px wide with 28 px corner radius, spaced 36 px apart. Center them as a group. Their bottom edge is `y=752`; use these heights from left to right: `520, 400, 280, 184, 280, 400, 520`. Fill the bars with `#E3A44B`.

Keep the artwork centered with generous clear space. Use vectors only. Do not rasterize, add text, add a drop shadow, or bake in a device-specific mask or corner treatment.

## Assemble it in Icon Composer

In Xcode, choose **Open Developer Tool → Icon Composer**, create a new app icon, and import the three SVG layers. Keep the layer order `background` → `pane` → `mark`. Assign the background to the background layer, and use the pane and mark as the foreground Liquid Glass layers. Check the appearance previews for Default, Dark, Clear, and Tinted. Also check the watchOS circular preview; the mark must remain legible and must not be clipped.

Save the result at:

`Voxglass/Resources/AppIcon.icon`

The `.icon` directory must be generated and saved by Icon Composer. Do not hand-write or flatten its `icon.json` file.

## Required handoff products

Please return all of the following:

- `Voxglass/Resources/AppIcon.icon`, intact as an Icon Composer package.
- The editable source file (Figma, Sketch, or Illustrator) with the three layers named `background`, `pane`, and `mark`, plus the 1024 px vector exports used to import them.
- Preview exports or screenshots for Default, Dark, Clear, Tinted, and the watchOS circular treatment.
- A short confirmation that the icon contains no text, no embedded raster images, no baked-in device mask, and no appearance-specific clipping.

Do not remove the existing icon until the new package has been built once for iPhone, watchOS, and the dedicated macOS target and visually checked in light and dark appearances.
