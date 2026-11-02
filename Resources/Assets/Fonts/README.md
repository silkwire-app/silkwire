# Archivo wordmark font

`Archivo-Italic-Variable-latin.woff2` is the unmodified Archivo italic variable
font from Jason's existing `silkwire-brand-kit/fonts/` (2026-10-20 brand kit).
Copyright 2020 The Archivo Project Authors
(https://github.com/Omnibus-Type/Archivo). Redistributed under the included
SIL Open Font License 1.1 (`OFL.txt`).

The native wordmark follows that kit's typography: all caps, italic, weight
400, expanded width 125, tracking 0.17em. Its 18 pt size fits alongside the
unchanged white/chrome spider in the sidebar. Body/UI typography is unchanged.

`Scripts/build.swift` copies the font, this note, and its license into the app's
`Contents/Resources/Fonts`. CoreText reads the original WOFF2 on macOS 14+
and registers it only for the app process. No font installation or network
request is needed. The descriptor comes from this bundled file so a local
font with a matching family name cannot substitute for the shipped face.
