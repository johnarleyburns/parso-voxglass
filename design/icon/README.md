# Voxglass layered app icon

1. Open Icon Composer via Xcode ▸ Open Developer Tool ▸ Icon Composer.
2. Create a new document and drag in `background.svg`, then `pane.svg`, then `mark.svg`. Keep them as separate groups stacked back to front.
3. Turn Liquid Glass off for the Background group. Turn it on for the Pane group, with about 50% translucency and a neutral shadow. Turn it on for the Mark group and enable specular highlights.
4. Check the Default, Dark, Clear (light and dark), and Tinted previews. If the mark loses legibility in Tinted, set its tinted appearance fill to white.
5. Check the watchOS circle preview with iOS, macOS, and watchOS enabled.
6. Save the document as `Voxglass/Resources/AppIcon.icon`.
