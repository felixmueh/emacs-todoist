# PLAN_SIMPLIFY

Baseline check: `make test` currently passes (`192/192`).

## [DONE] Phase 1 — Low-Hanging Fruit (safe cleanup + clarity)

1. **Low: Keep `fetch-items` and `item-complete`, but clarify intended usage.**  
Do **not** remove [`emacs-todoist-api-fetch-items`](emacs-todoist-api.el:316) or [`emacs-todoist-api-item-complete`](emacs-todoist-api.el:156). Instead, add explicit documentation/comment near `item_complete` that recurring-task completion should generally use `item_close` ([`emacs-todoist-api.el`](emacs-todoist-api.el:164)).

2. **Low: `emacs-todoist-frontend-buffer-name` should be single-source and reused for path building.**  
The variable is duplicated ([`emacs-todoist.el`](emacs-todoist.el:78), [`emacs-todoist-frontend.el`](emacs-todoist-frontend.el:23)), and frontend file path currently hardcodes `"todoist.org"` ([`emacs-todoist-frontend.el`](emacs-todoist-frontend.el:44)).

3. **Low: Sync-state property key lists are duplicated and should be centralized.**  
The same property set is hardcoded in multiple places, including deletion handling ([`emacs-todoist.el`](emacs-todoist.el:1089), [`emacs-todoist.el`](emacs-todoist.el:1096)) and capture relocation cleanup ([`emacs-todoist-frontend.el`](emacs-todoist-frontend.el:142)). A shared constant would remove repetition and drift risk.

4. **Low: Two one-use due-field helpers can be inlined or merged.**  
[`emacs-todoist--item-due-date`](emacs-todoist.el:461) and [`emacs-todoist--item-due-string`](emacs-todoist.el:467) are only used in one function ([`emacs-todoist.el`](emacs-todoist.el:495), [`emacs-todoist.el`](emacs-todoist.el:496)). They add names without reducing complexity meaningfully.

5. **Low: Replace inline item lookup lambdas with `emacs-todoist--find-item-by-id`.**  
`emacs-todoist--find-item-by-id` exists ([`emacs-todoist.el`](emacs-todoist.el:473)), but multiple call sites still inline equivalent `cl-find-if` ID matching logic. Replace those with the helper for consistency and readability (notably single-heading/bulk classification and force-pull call sites in [`emacs-todoist.el`](emacs-todoist.el)).

6. **Low: Add explicit cross-reference comments for hash-normalization functions.**  
Keep both normalization helpers separate by design: [`emacs-todoist-org--normalize-hash-string`](emacs-todoist-org.el:130) and [`emacs-todoist-api--normalize-hash-string`](emacs-todoist-api.el:208). Add comments that local-hash and remote-hash domains are independent and intentionally not unified.

7. **Low: Architecture docs are out of sync with code reality.**  
`AGENTS.md` still states 4 modules and old sizes/counts ([`AGENTS.md`](AGENTS.md:9), [`AGENTS.md`](AGENTS.md:24)), while repo now includes capture module and 192 non-live tests (observed via `make test`). This increases conceptual load for contributors.

8. **Medium: Bulk sync has repeated “unsynced TODO” filtering logic in three commands.**  
Same `cl-remove-if` block is duplicated in [`emacs-todoist-sync-buffer`](emacs-todoist.el:1659), [`emacs-todoist-sync-subtree`](emacs-todoist.el:1676), and [`emacs-todoist-sync-region`](emacs-todoist.el:1693). This should be one helper.

9. **Medium: Logging model is inconsistent (`warn` used but not modeled).**  
Log level choices/mapping only include debug/info/error ([`emacs-todoist.el`](emacs-todoist.el:112), [`emacs-todoist.el`](emacs-todoist.el:168)), yet `'warn` is used in multiple sync paths ([`emacs-todoist.el`](emacs-todoist.el:933), [`emacs-todoist.el`](emacs-todoist.el:1617)).

## Phase 2 — Module Ownership Boundaries (structural refactor)

1. **High: Enforce module ownership for capture code (keep it in `emacs-todoist-org-capture.el`).**  
Capture-specific behavior currently lives in integration (`emacs-todoist.el`), including `emacs-todoist-capture-to-frontend` ([`emacs-todoist.el`](emacs-todoist.el:152)) and helpers ([`emacs-todoist.el`](emacs-todoist.el:248), [`emacs-todoist.el`](emacs-todoist.el:266), [`emacs-todoist.el`](emacs-todoist.el:313)). Keep capture code/variables in [`emacs-todoist-org-capture.el`](emacs-todoist-org-capture.el), and remove routing variables entirely rather than consolidating them.

2. **Medium: Remove frontend-specific ownership leakage from `emacs-todoist.el`.**  
Frontend internals are referenced/defined in core integration (`emacs-todoist.el`), including internal autoload for [`emacs-todoist-frontend-insert-captured-subtree`](emacs-todoist.el:66), plus frontend vars ([`emacs-todoist.el`](emacs-todoist.el:75), [`emacs-todoist.el`](emacs-todoist.el:78)). Frontend ownership should stay in [`emacs-todoist-frontend.el`](emacs-todoist-frontend.el), which already defines the buffer variable ([`emacs-todoist-frontend.el`](emacs-todoist-frontend.el:23)).

## Phase 3 — Capture Flow Simplification (structural behavior change)

1. **High: Remove capture routing/relocation logic entirely; capture directly into frontend file.**  
The routing path exists from the pre-file-backed frontend era and adds unnecessary complexity (`--capture-process-marker`, relocation, fallback branches). Replace it with a simpler model: the capture template writes directly into the frontend file and finalize only pushes that heading in place.

2. **High: Remove deferred capture finalize path for this flow.**  
With direct capture into the correct frontend file, defer/relocation machinery is no longer needed in this path (`emacs-todoist--capture-defer` and related routing dispatch usage). Keep finalize straightforward: push captured heading directly from capture hook.

## Phase 4 — Frontend Bootstrap Semantics (structural sync behavior)

1. **High: Add explicit frontend bootstrap rule: first frontend sync is always full (`*`).**  
To avoid partial state when a freshly captured+synced heading has a very recent token, frontend sync bootstrap must not start incremental. Ensure first `emacs-todoist-frontend-sync` pass does a full fetch (`*`) before using heading tokens for incremental sync ([`emacs-todoist-frontend.el`](emacs-todoist-frontend.el:317)).

2. **High: Document why frontend bootstrap is required.**  
Add a code comment plus user-facing doc note describing the token pitfall: a frontend file seeded by capture can otherwise miss older remote items indefinitely if initial sync is incremental. State explicitly that first frontend sync is always full by design.

## Phase 5 — Sync Command Unification (final structural pass)

1. **Done: Remove `emacs-todoist-sync-heading` and use subtree sync as the default path.**  
`emacs-todoist-sync-heading` has been removed. Subtree sync is now the default heading-triggered path via `emacs-todoist-sync-subtree` and `emacs-todoist-mode` auto-sync.

2. **Done: Keep `emacs-todoist-sync-single-heading` for explicit N=1 behavior.**  
`emacs-todoist-sync-single-heading` is the explicit heading-only command. It syncs only the heading at point and intentionally does not reconcile descendant headings.

3. **Done differently: child-first pull ordering is no longer part of the design.**  
Accepted remote TODO-state changes are now applied textually via `emacs-todoist-set-todo-state`, so Org blocker semantics do not force special child-first pull ordering.

4. **Done: update call sites/docs to reflect the command split.**  
Call sites and docs now distinguish subtree sync from explicit single-heading sync.
