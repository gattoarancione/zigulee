# Example fonts

Fonts bundled for the examples and the golden-image tests. zigulee itself does
not ship or require any font; applications provide their own.

| Font | Files | Version | License |
|---|---|---|---|
| [Inter](https://github.com/rsms/inter) | `inter/Inter-Regular.ttf`, `inter/Inter-Bold.ttf` | 4.1 (static TTFs from `extras/ttf`) | SIL Open Font License 1.1 (`inter/LICENSE.txt`) |
| [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) | `jetbrains-mono/JetBrainsMono-Regular.ttf` | 2.304 | SIL Open Font License 1.1 (`jetbrains-mono/LICENSE.txt`) |

Inter kerns only through its GPOS table (including extension lookups), so
it also exercises zigulee's GPOS kerning.
