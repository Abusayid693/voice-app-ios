# VariableBlur

Vendored unmodified from [nikstar/VariableBlur](https://github.com/nikstar/VariableBlur)
(MIT, originally by [jtrivedi](https://github.com/jtrivedi/VariableBlurView)).
Update by re-copying `VariableBlur.swift` from upstream rather than
hand-editing, same convention as `ThinkingOrbsKit`.

True variable-radius blur — the blur strength at each pixel follows a
gradient mask, rather than one fixed-radius blur faded by opacity. There is
no public API for this: it applies a private `CAFilter` named
`"variableBlur"` to a `UIVisualEffectView`'s backdrop layer, with the class
and selector names reversed-string-obfuscated in the source (upstream's own
choice, not this project's). The author reports this has not triggered App
Store rejection; it remains an unlisted API Apple could change in a future
OS, which would silently stop the blur rather than crash.

First (only) consumer: `DesignSystem/InteractiveGlassBottomSheet.swift`'s
header.

## Usage

```swift
.overlay(alignment: .top) {
    VariableBlurView(maxBlurRadius: 20, direction: .blurredTopClearBottom)
        .frame(height: 78)
}
```

No background of its own — composite directly over scrolling content, never
over an opaque fill, or the "blur" reads as a flat color block instead of
glass.
