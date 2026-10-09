# Catalog artwork source

- `standard-ebooks-logo.png` — Standard Ebooks' official website logo:
  <https://standardebooks.org/images/logo.png>
- `explainer.mp4` — source screen recording for the catalog introduction.

Source files are kept unmodified. The Standard Ebooks mark has an optimized
copy in `Assets.xcassets`. `explainer.mp4` is transcoded to the bundled
`Sources/Resources/catalog-explainer.mp4` as 360px-wide H.264 with its audio
stream removed. Project Gutenberg uses a code-native `PG` monogram rather than
bundled trademark artwork.
