# Branch: `codex/manual-highlights`

## Goal

Let users create their own highlights separately from AI-generated highlights.

## Scope

- Allow text selection in the PDF viewer to become a user highlight.
- Render user highlights with a different color from AI highlights.
- Store user highlights separately from AI highlights.
- Keep imported PDFs unmodified as source files.
- Add a simple remove action if time allows.

## Out Of Scope

- Rich annotation notes.
- Highlight comments.
- Sync.
- Export.

## Likely Files

- `Sources/Axiom/AppUI.swift`
- `Sources/Axiom/TextbookStore.swift`
- `Sources/Axiom/Models.swift`
- `Sources/Axiom/Verification.swift`

## Suggested Implementation Steps

1. Add a user-highlight model.
2. Add a SQLite table for user highlights.
3. Add a command or context menu item for selected text.
4. Save page index, exact text, range location, and range length.
5. Render user highlights separately from `AxiomAutoHighlight`.
6. Add a verify case for storing and loading user highlights.

## Acceptance Criteria

- User-created highlights persist after closing and reopening a document.
- AI highlights and user highlights are visually distinct.
- Clearing or retrying AI analysis does not delete user highlights.
- User highlights do not modify the original PDF file.

## Verification

```bash
swift build
swift run Axiom --verify
```

Manual check:

1. Run `swift run Axiom`.
2. Select text in a PDF.
3. Create a manual highlight.
4. Navigate away and back.
5. Confirm the manual highlight remains.
