# Branch: `codex/pet-overlay`

## Goal

Add the decorative AI pet to the PDF reader and use it to visualize AI activity.

## Dependency

Start after `codex/mvp-spec-and-pet-assets` is merged, or rebase onto it while developing.

## Scope

- Load one fixed MVP pet.
- Render the pet above the PDF viewer.
- Animate the pet when page analysis starts.
- Give feedback when highlights appear.
- Allow the pet to be dragged.
- Add dismiss and disable controls.
- Keep the pet decorative; it should not own AI logic.

## Out Of Scope

- Multiple pet personalities.
- Pet selection UI.
- Cross-document reasoning.
- Chat behavior.

## Likely Files

- `Sources/Axiom/AppUI.swift`
- `Sources/Axiom/Models.swift`, only if a small pet model is needed
- `Sources/Axiom/Resources/**`, if bundled assets are used
- `Package.swift`, if new resource rules are required
- `README.md`, for pet behavior notes

## Suggested Implementation Steps

1. Add a small `PetOverlayView` or equivalent AppKit view.
2. Place it in the reader root view above `PDFView`.
3. Load the default pet image or spritesheet.
4. Add simple animation states: idle, analyzing, highlight-complete.
5. Wire analyzing state from the existing page-analysis flow.
6. Add drag handling.
7. Add dismiss and disable state.

## Acceptance Criteria

- The pet appears in the reader.
- The pet never blocks normal PDF reading controls.
- The pet animates while AI analysis is running.
- The pet can be dragged.
- The pet can be dismissed for the current session.
- The pet can be disabled.

## Verification

```bash
swift build
swift run Axiom --verify
```

Manual check:

1. Run `swift run Axiom`.
2. Open a textbook.
3. Wait on a page long enough to trigger AI analysis.
4. Confirm the pet changes state and highlights still render.
