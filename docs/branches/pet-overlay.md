# Branch: `codex/pet-overlay`

## Goal

Add the Codex pet to the PDF reader with the same sprite states, playback rules, hover behavior, and drag feedback as Codex Pets, then use its existing states to visualize page-analysis activity.

## Dependency

Start after `codex/mvp-spec-and-pet-assets` is merged, or rebase onto it while developing.

## Implemented Contract

- Use Codex as the fixed MVP pet.
- Bundle the existing `pet.json` and `spritesheet.webp` under `Sources/Axiom/Resources/Pets/codex/`.
- Render the pet at the compact 80-point width and the atlas's `192:208` aspect ratio.
- Validate the version-2 atlas as 8 columns by 11 rows before showing it.
- Use the six idle frames and exact Codex frame durations, multiplied by Codex's six-times idle slowdown.
- Play a non-idle reaction three times, then remain in the slowed idle loop.
- Use jumping on hover and directional running while dragging.
- Start directional drag feedback at four points and shrink the sprite to 95% over 160 ms.
- Clamp dragging to the PDF viewer and persist the normalized position.
- Use a still first frame when macOS Reduce Motion is enabled.
- Map analysis activity to running, needs-input to waiting, failure to failed, and completed highlights to review.

## Scope

- Load one fixed MVP pet.
- Render the pet above the PDF viewer.
- Match the Codex animation and interaction contract for the bundled version-2 sprite.
- Animate the pet when page analysis starts and give feedback when highlights appear.
- Allow the pet to be dragged and remember its position.
- Keep the pet decorative; it should not own AI logic.

## Out Of Scope

- Multiple pet personalities.
- Pet selection UI.
- Cross-document reasoning.
- Chat behavior.
- Click actions, dismiss, and disable controls.

## Changed Files

- `Sources/Axiom/AppUI.swift`
- `Sources/Axiom/PetOverlay.swift`
- `Sources/Axiom/Verification.swift`
- `Sources/Axiom/Resources/Pets/codex/**`
- `README.md`, for pet behavior notes

## Suggested Implementation Steps

1. Encode the official atlas rows, frame counts, and durations as a testable contract.
2. Build playback sequences for idle, reactions, and reduced motion.
3. Render the overlay above `PDFView` with nearest-neighbor image interpolation.
4. Add hover and directional drag state precedence.
5. Clamp and persist the dragged position.
6. Wire activity states from the existing page-analysis flow.
7. Verify all animation cells, timing sequences, state precedence, and positioning math.

## Acceptance Criteria

- The pet appears in the reader.
- Idle playback has the Codex cadence rather than a rapid uniform loop.
- Hover plays jumping and leaving hover returns to the current activity state.
- The pet animates while AI analysis is running.
- The pet uses waiting, failed, and review feedback for the matching reader states.
- The pet can be dragged with directional animation and stays within the PDF viewer.
- The dragged position survives reopening the reader.
- Reduce Motion produces a static first frame.

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
5. Hover the pet and confirm it jumps before returning to the current state.
6. Drag it left and right; confirm the direction changes, it stays in bounds, and its position is restored after reopening the reader.
7. Enable Reduce Motion in macOS Accessibility settings and confirm the pet uses a still frame.
