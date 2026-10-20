# Review: AI-assisted SSIS → ADF migration plan

Reviewed 2026-10-20. Inputs: [`source/plan.md`](source/plan.md) and
[`source/ssis_migration_assessment_blueprint.pdf`](source/ssis_migration_assessment_blueprint.pdf).
Tracking workbook (issues with owner/status, recommended pipeline, next steps):
[`SSIS_ADF_Plan_Review.xlsx`](SSIS_ADF_Plan_Review.xlsx).

## Verdict

The plan's core shape is sound: strip packages deterministically, generate with AI, finish with
human review. Three changes are recommended:

1. **Deterministic routing and validation** — not AI triage. The assessment script already routes reproducibly.
2. **AI only where translation needs judgment** — mechanical conversions come from templates.
3. **Data-equivalence testing as the quality gate** — schema validation alone can pass a pipeline that loads the wrong rows.

The blueprint PDF ends with a chatbot "medical advice" disclaimer, so its specifics are treated as
unverified drafts.

## Factual corrections (selection)

| Plan item | Correction |
| --- | --- |
| Phase 0: Microsoft DMA | DMA is deprecated, and its SSIS rules target the Azure-SSIS IR, not ADF-native rewrites. Use the assessment script. |
| `@[System::PackageName]` → `@pipeline().DataFactory` | Wrong: the pipeline name is `@pipeline().Pipeline`. |
| Script Tasks → Azure-SSIS IR; heavy transforms → Databricks | Contradicts Option D; use the decision document's routes. |
| Model names, context limits, Copilot CLI/BYOK syntax | Unverified; design must not depend on them. |

## Recommended pipeline

| Stage | Engine | Owns correctness |
| --- | --- | --- |
| 0. Inventory and route | Assessment script | Deterministic rules |
| 1. Extract rewrite spec | `-ExportRewriteSpec` (planned) | Deterministic parser |
| 2a. Generate AdfNative-Low | Templates | Templates, reviewed once |
| 2b. Generate AdfNative-Medium | AI with spec, examples, required output schema | Stage 3 tests |
| 3. Verify | Lint, deploy to Dev via Git, side-by-side run in Test | Row counts + checksums |
| 4. Review and promote | Pull request + standard ADF CI/CD | Human approver |

Start with a 5–10 package pilot across Low and Medium; measure first-pass acceptance and test defects
before scaling.
