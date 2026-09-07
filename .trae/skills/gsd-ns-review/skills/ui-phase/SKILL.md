---
name: gsd-ui-phase
description: "Generate UI design contract (UI-SPEC.md) for frontend phases"
stage: workflow
---

<objective>
Create a UI design contract (UI-SPEC.md) for a frontend phase.
Orchestrates gsd-ui-researcher and gsd-ui-checker.
Flow: Validate → Research UI → Verify UI-SPEC → Done
</objective>

<execution_context>
@/Users/smintz/git/platform-engineering/.trae/gsd-core/workflows/ui-phase.md
@/Users/smintz/git/platform-engineering/.trae/gsd-core/references/ui-brand.md
</execution_context>

<context>
Phase number: {{GSD_ARGS}} — optional, auto-detects next unplanned phase if omitted.
</context>

<process>
Execute end-to-end.
Preserve all workflow gates.
</process>
