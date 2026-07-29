---
name: dbt-tooling-setup
description: >
  Use when setting up or troubleshooting dbt tooling — onboarding a developer,
  configuring SQLFluff with the dbt templater, VS Code extensions like dbt Power
  User, choosing and pinning community packages in packages.yml (dbt-utils,
  dbt-codegen, dbt_project_evaluator, dbt_expectations, elementary), or
  evaluating optional AI tooling such as dbt Wizard.
---

# dbt Tooling & Onboarding

Source of truth: [`docs/technical-guidelines/dbt/third-party-tooling.md`](../../../docs/technical-guidelines/dbt/third-party-tooling.md)

The two tools that matter most: **dbt Power User** in VS Code, paired with **SQLFluff**
linting configured for dbt templating. Everything else is optional.

## Onboarding a developer

```sh
pip install dbt-<adapter>
pip install "sqlfluff[dbt]"
dbt deps                      # before the first dbt build
sqlfluff lint models/         # fix or baseline before opening a PR
```

Set `DBT_PROFILES_DIR` (environment variable or VS Code setting). Recommend extensions via
`.vscode/extensions.json`:

```json
{
  "recommendations": [
    "innoverio.vscode-dbt-power-user",
    "ms-python.python",
    "ms-toolsai.jupyter",
    "ms-vscode.powershell"
  ]
}
```

## dbt Power User

Primary VS Code extension for dbt navigation and documentation.

- Graph and lineage browsing from manifest artifacts — point it at `target/manifest.json`
  for accurate lineage.
- `ref()`/`source()` auto-complete and quick-open of dependent models.
- Inline editing of model/column descriptions, which is the fastest way to drive down
  undocumented items.
- Enable **Generate Documentation Stub** so `_models.yml` stays synchronized as models
  are added.

## SQLFluff

Enforces consistent SQL/Jinja style and catches templating errors before CI does.

```ini
[sqlfluff]
dialect = ansi
templater = dbt
exclude_rules = L009

[tool:sqlfluff:templater:dbt]
project_dir = .
profiles_dir = .
```

```sh
sqlfluff lint models --format github-annotation
sqlfluff fix models --force     # always review the diff
```

Set `dialect` to your actual warehouse dialect (`databricks`, `tsql`, `snowflake`, …) rather
than leaving `ansi` in place. `templater = dbt` is what makes it Jinja-aware — without it,
every `{{ ref() }}` is a parse error.

## Community packages

Use a **small, pinned** set. Evaluate maintenance, adapter support, and performance before
adopting anything new.

| Package | Why use it | Guardrails |
|---|---|---|
| `dbt-utils` | Canonical macros and reusable tests | Default include; pin the version |
| `dbt-codegen` | Generate YAML/model stubs to accelerate docs | Review generated code; don't commit unedited |
| `dbt_project_evaluator` | Governance checks for structure/tests | Run in CI on a schedule; validate findings before blocking |
| `audit_helper` | Lightweight reconciliation patterns | Scope to critical flows; keep configs adapter-agnostic |
| `dbt_expectations` | Rich expectations-style tests | Powerful but slow on large tables; sample or partition |
| `dbt-bounce` | Validate refs/tests connectivity | Optional dependency sanity check |
| `elementary` | Monitoring/observability for dbt runs | Adds overhead; justify for teams needing run-time telemetry |

```yaml
# packages.yml — never float a version
packages:
  - package: dbt-labs/dbt_utils
    version: 1.1.1
```

Review package upgrades alongside dbt-core minor releases.

## Optional tooling

**dbt VS Code Extension (Fusion Engine preview)** — experimental Fusion Engine completion
and semantic cues. An add-on alongside dbt Power User for teams wanting graph-aware hints.
Keep lint and tests as the source of truth, disable conflicting shortcuts, and validate
features per adapter.

**dbt Wizard (AI agent)** — an AI dev agent purpose-built for dbt. Unlike general-purpose
coding agents, it's grounded in a native metadata engine (lineage, model health, tests,
contracts, run results, semantic definitions) rather than just reading files, so it
understands how a project connects before changing anything.

- Checks upstream/downstream dependencies before changing code, then compiles and builds
  changes before surfacing them. Approval mode shows every change as a diff first.
- Fits building (models + tests/docs/semantic definitions), lineage-aware debugging, and
  migrations (updates every `ref`, test, and YAML config with a reviewable diff).
- Surfaces: terminal CLI (`wizard` on PATH, works with dbt Core or Fusion) or a chat-first
  workspace in Studio IDE.
- **Licensing guardrail:** bring-your-own-key requires a direct Anthropic API key —
  Anthropic enterprise/subscription plans (e.g. Claude Enterprise) are not supported. A
  ChatGPT subscription can be connected. *(Accurate as of July 2026 — re-verify.)*
- Treat as optional and evaluate before adopting, same as the Fusion Engine preview.

## Checklist

- [ ] `dbt deps` runs clean and every package in `packages.yml` has a pinned version.
- [ ] `.sqlfluff` sets the correct warehouse `dialect` and `templater = dbt`.
- [ ] `sqlfluff lint models/` passes (or has an agreed baseline) before the PR.
- [ ] `.vscode/extensions.json` recommends dbt Power User.
- [ ] `DBT_PROFILES_DIR` is set and no credentials are committed.
