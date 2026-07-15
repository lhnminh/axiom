# Axiom MVP Branch Plan

This folder splits the current `dev.md` MVP into feature branches that can be worked on in parallel.

The current app already has folder import, PDF browsing, original PDF viewing, page-scoped AI highlighting, SQLite caching, and a verification harness. The remaining MVP work should stay focused on pet integration, chat, user highlights, and reading-safety polish.

## Recommended Branches

| Order | Branch | Primary Goal | Parallel? |
| --- | --- | --- | --- |
| 1 | `codex/mvp-spec-and-pet-assets` | Commit the MVP spec and normalize pet assets | First |
| 2 | `codex/pet-overlay` | Show and control the AI pet in the reader | Yes, after assets |
| 3 | `codex/persistent-ai-chat` | Replace the right detail-only panel with persistent chat | Yes |
| 4 | `codex/manual-highlights` | Add user-created highlights separate from AI highlights | Yes |
| 5 | `codex/highlight-safeguards` | Prevent distracting or duplicate automatic highlighting | Yes |
| 6 | `codex/mvp-polish-demo` | Merge, verify, and prepare the demo flow | Last |

## Suggested Owner Split

- Teammate A: `codex/persistent-ai-chat`
- Teammate B: `codex/pet-overlay`
- Next available: `codex/manual-highlights`
- Next available: `codex/highlight-safeguards`
- Shared final pass: `codex/mvp-polish-demo`

## Branch Creation

Create each branch from a clean `master` unless the branch doc lists a dependency.

```bash
git checkout master
git pull
git checkout -b codex/mvp-spec-and-pet-assets
```

For dependent branches, branch from the dependency after it is merged, or rebase onto `master` after the dependency lands.

## Merge Order

1. `codex/mvp-spec-and-pet-assets`
2. `codex/persistent-ai-chat`
3. `codex/pet-overlay`
4. `codex/manual-highlights`
5. `codex/highlight-safeguards`
6. `codex/mvp-polish-demo`

`persistent-ai-chat`, `manual-highlights`, and `highlight-safeguards` can be developed at the same time, but expect small conflicts in `Sources/Axiom/AppUI.swift`.

## Branch Docs

- [MVP spec and pet assets](mvp-spec-and-pet-assets.md)
- [Pet overlay](pet-overlay.md)
- [Persistent AI chat](persistent-ai-chat.md)
- [Manual highlights](manual-highlights.md)
- [Highlight safeguards](highlight-safeguards.md)
- [MVP polish demo](mvp-polish-demo.md)
