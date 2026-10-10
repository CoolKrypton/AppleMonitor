# Fonts

The UI ships **without bundled font binaries** on purpose — the two display
faces below are licensed for redistribution but are not committed here, so the
repo stays small and licence-clean.

The app renders correctly without them: it falls back to the platform default
sans-serif and all layout is driven by measured metrics rather than glyph
widths, so nothing breaks. The "futuristic instrument" feel is simply stronger
with the display face installed.

## Optional: enable the HUD typefaces

1. Download these two families (both are SIL Open Font License):

   | Role | Family | Suggested weights | Source |
   | --- | --- | --- | --- |
   | Numerals, headings, the clock | **Orbitron** | Regular 400, SemiBold 600, Bold 700 | <https://fonts.google.com/specimen/Orbitron> |
   | Labels, body copy | **Rajdhani** | Medium 500, SemiBold 600 | <https://fonts.google.com/specimen/Rajdhani> |

2. Drop the `*.ttf` files into this directory (`assets/fonts/`).

3. Uncomment the `fonts:` block in `pubspec.yaml` (the entries are already
   written out — you only need to remove the leading `#` characters).

4. Re-run `flutter pub get` and restart the app.

## Tabular figures

The numeric readouts rely on `FontFeature.tabularFigures()` (see
`lib/util/format.dart`), so digits keep a constant width and the values do not
jitter as they update. Orbitron and Rajdhani both provide tabular figures; if
you swap in another family, prefer one that does too — otherwise the 20 Hz
bar/graph updates can cause visible digit shimmer.

## Expected layout impact

`lib/util/format.dart` contains `measureDigits()`, which estimates a numeral's
width from `fontSize * 0.58`. That constant matches the default sans-serif.
After installing Orbitron you may want to re-tune it slightly (orbitron digits
are marginally wider) — it only affects the "will this text overflow" checks,
never correctness.
