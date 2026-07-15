# Branch: `codex/mvp-spec-and-pet-assets`

## Goal

Commit the MVP specification and make the pet asset location intentional before UI work starts.

## Why This Branch Exists

`dev.md` describes the current MVP target, and `codex-pets/` contains the added pet assets. Both are currently untracked. The pet overlay branch should not have to decide asset ownership and UI behavior at the same time.

## Scope

- Commit `dev.md`.
- Decide whether to keep pet assets in `codex-pets/` or move them under `Sources/Axiom/Resources/Pets/`.
- Keep the pet package contract clear: one folder per pet, each with `pet.json` and `spritesheet.webp`.
- Document which pet is the MVP default.
- Avoid app UI changes.

## Likely Files

- `dev.md`
- `codex-pets/codex/pet.json`
- `codex-pets/codex/spritesheet.webp`
- `codex-pets/dewey/pet.json`
- `codex-pets/dewey/spritesheet.webp`
- `README.md`
- `Package.swift`, only if assets move into SwiftPM resources

## Acceptance Criteria

- The MVP spec is versioned.
- Pet assets are versioned or intentionally excluded.
- The default MVP pet is named in docs.
- A developer can tell where pet assets should be loaded from.

## Verification

```bash
git status --short
swift build
```

## Notes

If assets stay outside `Sources/Axiom/Resources`, the pet overlay branch will need a clear runtime lookup path. If assets move into `Sources/Axiom/Resources`, SwiftPM can bundle them with the executable.
