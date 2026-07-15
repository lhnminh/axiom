# Branch: `codex/highlight-safeguards`

## Goal

Make automatic highlighting helpful without becoming distracting or repetitive.

## Scope

- Limit the number of automatic highlights per page.
- Prevent duplicate highlights.
- Avoid repeatedly highlighting the same sentence.
- Avoid triggering analysis while users are actively scrolling.
- Keep page-on-demand analysis and caching behavior intact.

## Out Of Scope

- Reading behavior analysis.
- Struggle detection.
- Adaptive personalization.
- Interactive highlight explanations.

## Likely Files

- `Sources/Axiom/AppUI.swift`
- `Sources/Axiom/MathAnalysis.swift`
- `Sources/Axiom/TextbookStore.swift`
- `Sources/Axiom/Verification.swift`

## Suggested Implementation Steps

1. Define an MVP max highlight count per page.
2. Normalize candidate text before duplicate checks.
3. Apply duplicate filtering before saving analysis results.
4. Track scroll/page-change stability before analysis starts.
5. Add logs that explain why analysis was skipped or delayed.
6. Add verification for duplicate filtering.

## Acceptance Criteria

- A page cannot render excessive AI highlights.
- Duplicate model candidates do not create duplicate annotations.
- Fast scrolling does not trigger a burst of stale page analyses.
- Existing cache hits still render quickly.

## Verification

```bash
swift build
swift run Axiom --verify
```

Manual check:

1. Open a long PDF.
2. Scroll quickly across several pages.
3. Stop on one page.
4. Confirm only the settled page is analyzed.
