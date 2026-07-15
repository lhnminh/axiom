# Branch: `codex/mvp-polish-demo`

## Goal

Merge the MVP work, remove rough edges, and prepare the 3-minute demo flow.

## Dependency

Start after the other MVP feature branches are merged.

## Scope

- Resolve integration issues across chat, pet, highlights, and safeguards.
- Update README instructions.
- Confirm the demo flow from `dev.md`.
- Make UI labels consistent with the Axiom name.
- Run the verification harness.
- Document known limitations.

## Out Of Scope

- New product features.
- Cross-document retrieval.
- Multiple pets.
- Flashcards or quizzes.

## Likely Files

- `README.md`
- `dev.md`
- `Sources/Axiom/AppUI.swift`
- `Sources/Axiom/Verification.swift`
- Any file touched by merge conflicts

## Demo Flow

1. Import a folder of PDFs.
2. Browse the imported PDFs.
3. Open a document.
4. Wait on a page.
5. Show the pet reacting to AI analysis.
6. Show automatic highlights appearing.
7. Ask a question in the persistent AI chat.

## Acceptance Criteria

- The app builds from a clean checkout.
- The verification harness passes.
- The demo can be run without explaining missing MVP pieces.
- README matches the current behavior.
- Known limitations are documented clearly.

## Verification

```bash
swift build
swift run Axiom --verify
```

Manual check:

1. Run `swift run Axiom`.
2. Complete the demo flow above.
3. Confirm there are no obvious UI blockers.
