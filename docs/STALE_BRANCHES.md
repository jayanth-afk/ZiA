# Stale Branch Report (Phase 1.3)

> Contract v1.0. Generated 2026-10-07 · HEAD `4f979f2` · **read-only** — no branch
> was merged, deleted, or modified.

## Summary

Both locally-present feature branches are **fully superseded** by `master`. They
share the same merge base (`a591fe6`, the Milestone 1–3 baseline) and are now
**104 commits behind** `master`. Every symbol they introduce already exists on
`master`, in a later and more complete form. **Nothing is missing from master.**

## `freebuff/verification-subsystem`

- Ahead of master by 3 commits: `02ee623` (observation machinery), `83fd86c`
  (file-content verification in `RunShellTool` + `ToolExecutor` DI), `6c7d844`
  (`del` — deletes the committed `Jarvis.app` bundle).
- Superseded by master: `FileSystemObserver.swift` exists on master;
  `AccessibilityBridge.elementExists/isElementFocused/readElementValue` exist on
  master (lines 114/135/140); the 5-state `ToolVerificationResult` and
  metadata-aware `verifyDetailed` exist on master. No branch-only source file.

## `gemini/milestone4-verification`

- Ahead of master by 3 commits: `7fd91c8` (Milestone 4A contract), `a76b869`
  (`FileSystemObserver` + AX observation methods), `5dc9232` (`del`).
- Superseded by master for the same reasons as above. The only extra file it
  touches relative to its own base is a `PROJECT_CONTEXT.md` section that
  `master`'s refreshed documentation now covers.

## What differs (why they look big)

The `merge-base..branch` diffs are dominated by **deletions of committed build
artifacts** (`build/Jarvis.app/...`, `_CodeSignature`, tokenizer resource
bundles) performed by the branches' trailing `del` commit — not by unique
feature work. The `Sources/` diffs (Milestone 4A verification) are matched or
exceeded on `master`.

## Recommendation

Delete both branches once the owner approves (they add nothing and keep the
remote ahead of a stale baseline). **Queued as AQ-5 — PENDING OWNER.** No action
taken by this executor.
