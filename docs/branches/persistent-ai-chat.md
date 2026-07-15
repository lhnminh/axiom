# Branch: `codex/persistent-ai-chat`

## Goal

Turn the right side of the reader into a persistent AI chat while preserving highlight details.

## Scope

- Replace the current details-only `NSTextView` sidebar with a chat-oriented right panel.
- Keep chat history visible while changing pages.
- Send user questions to the configured AI provider.
- Use current-page context for the first MVP version.
- Keep AI highlight details available in the same panel or a secondary section.
- Show clear empty, loading, error, and missing API-key states.

## Out Of Scope

- Entire-document RAG.
- Entire-folder RAG.
- Cross-document citations.
- Streaming responses, unless trivial with the existing provider code.

## Likely Files

- `Sources/Axiom/AppUI.swift`
- `Sources/Axiom/MathAnalysis.swift`
- `Sources/Axiom/Models.swift`
- `Sources/Axiom/TextbookStore.swift`, only if chat history is persisted
- `README.md`

## Suggested Implementation Steps

1. Extract the right panel into a dedicated view/controller.
2. Add chat transcript and input controls.
3. Keep existing highlight details as a collapsible or separate section.
4. Add a current-page chat prompt that includes page text and current highlights.
5. Reuse the configured Gemini/OpenAI provider path where possible.
6. Add local in-memory chat history first.
7. Persist chat history only if time allows.

## Acceptance Criteria

- A user can ask a question from the reader view.
- The AI answer uses the current page as context.
- Chat history stays visible while navigating pages in the same document.
- Highlight details are still accessible.
- Missing provider configuration produces a useful message instead of failing silently.

## Verification

```bash
swift build
swift run Axiom --verify
```

Manual check:

1. Run `swift run Axiom`.
2. Open a textbook.
3. Ask a question about the visible page.
4. Change pages and confirm the transcript remains.
