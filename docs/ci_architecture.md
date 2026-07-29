# Slim CI architecture

How pull-request validation builds only what changed, in full isolation, while
reading everything unchanged from a stable baseline. Pipeline setup lives in
[`cicd/README.md`](../cicd/README.md); this document explains the design.

## The one command

```bash
dbt build --target ci --selector ci_modified --state state_dev --defer
```

One manifest, two roles:

| Manifest artifact  | Produced by                  | Produced how                        | Roles |
| ------------------ | ---------------------------- | ----------------------------------- | ----- |
| `dbt-manifest-dev` | `build-dev` (merge to `dev`) | `dbt build --target ci --selector full_build` | **Selection** (`--state`) — which nodes count as *modified* vs. `dev`<br>**Defer** (`--defer-state`, defaults to `--state`) — where refs to *unmodified* nodes resolve to |

The `ci_modified` selector ([`selectors.yml`](../selectors.yml)) picks
`modified+`: everything that changed relative to the dev manifest, plus
downstream dependents. Those nodes are built into the PR's own schema (below).
Every `ref()` to a node **not** selected resolves to the location recorded in
that same manifest — `<CI_DB>.<layer schema>.<table>` — i.e. the dev baseline
that `build-dev` materialized in the CI warehouse.

## ⚠️ The invariant that makes defer safe

> **The manifest you defer to must have been produced by the run that
> materialized the relations it describes.**

A manifest from `dbt compile` describes **code**. Defer needs a description of
**relations that exist**, with the columns they actually have. Point
`--defer-state` at a compiled manifest and CI will happily emit
`select dbt_batch_id from <db>.<schema>.<table>` for a column that was never
materialized, failing at runtime with SQL `42S22 — Invalid column name`.

This is why [`build-dev`](../.github/workflows/build-dev.yml) runs a real
`dbt build` and publishes *its own* manifest. Weakening that step back to
`dbt compile` re-breaks slim CI with no error at deploy time — only later, in
somebody's PR.

The same reasoning rules out deferring to **accept** here: the accept and prod
warehouses are materialized by the Fabric runtime from OneLake-deployed code on
its own schedule (see [`cicd/scripts/deploy_to_onelake.sh`](../cicd/scripts/deploy_to_onelake.sh)),
so no pipeline can publish a manifest that provably matches their contents.
`deploy-accept` therefore publishes no state artifact at all.

Deferring to a baseline in the CI warehouse is safe from cross-PR contamination
because of the `pr_<N>` isolation below: PR builds write **only** to `pr_<N>`,
so nothing but `build-dev` ever writes the layer schemas that defer reads.

## ⚠️ Workspace colocation requirement (infra prerequisite)

Sources compile to three-part names (`<LH_source>.<schema>.<table>`).
**Fabric only allows cross-database queries between items in the SAME
workspace.** Therefore:

> The **CI warehouse** and the **`LH_source` lakehouse** (declared as
> `database:` in the `_sources.yml` files) must live in **one Fabric
> workspace**, and the CI service principal needs read access to it.

Deferred refs no longer add a requirement of their own: they resolve inside the
CI warehouse (`<CI_DB>`), so the accept warehouse need not be colocated.

This cannot be enforced from code. The `ci` pipeline runs a smoke test before
building — `dbt run-operation assert_cross_db_access` probing
`SELECT TOP 1 1 FROM [<LH_source>].INFORMATION_SCHEMA.TABLES` (the database
name is taken from the downloaded manifest's sources, so no extra pipeline
variable is needed) — and fails fast with a colocation hint if the read is not
possible.

## PR schema lifecycle

`generate_schema_name` ([`macros/generate_schema_name.sql`](../macros/generate_schema_name.sql))
routes **all** models of a CI run into one flat schema `pr_<PR number>` when
`DBT_CI_SCHEMA_SUFFIX` is set (the pipelines set it from the PR number; when it
is unset — local `--target ci` runs, `build-dev` — behavior is unchanged).

| Event                | Effect on the CI warehouse |
| -------------------- | -------------------------- |
| Merge to `dev`       | `build-dev` rebuilds the whole project into the canonical layer schemas (`bronze_sales`, `silver`, `gold`) — the defer baseline |
| PR opened / pushed   | modified+ models built into `pr_<N>` (a new push cancels the in-flight run — same concurrency group) |
| PR closed (merged or abandoned) | `ci-cleanup` drops every object in `pr_<N>`, then the schema (`drop_pr_schema` macro; Fabric has no `DROP SCHEMA ... CASCADE`) |

The `drop_pr_schema` macro only accepts names matching `^pr_[0-9]+$`, so it can
never touch real schemas. On Azure DevOps there is no PR-closed trigger; the
`ci-cleanup` pipeline there runs manually (single schema) or as a weekly sweep
(`drop_all_pr_schemas`) — the sweep may drop schemas of still-open PRs, which
is harmless: nothing reads `pr_` schemas between runs, and the next push
rebuilds them.

## What this design prevents

- **Cross-PR contamination.** Previously all PRs built into the shared
  `<CI_DB>` layer schemas and deferred to that same location: PR B's
  unmodified refs read tables last written by PR A's unmerged — possibly
  abandoned — code. Now every PR writes only to `pr_<N>`, and the layer schemas
  it defers to are written by `build-dev` alone.
- **Stale / drifting baseline.** The defer target used to be whatever the CI
  workspace happened to contain, then briefly the accept warehouse — which no
  pipeline materializes, so its manifest was a description of code rather than
  of tables. Now the baseline is rebuilt by the same run that publishes the
  manifest describing it, on every merge to `dev`.
- **Concurrent-run interference.** Per-PR concurrency groups
  (cancel-in-progress) plus per-PR schemas make simultaneous runs of different
  PRs fully independent, and repeated pushes to one PR idempotent.

## Fallbacks and edge cases

| Situation | Behavior |
| --------- | -------- |
| `dbt-manifest-dev` missing (first run, expired retention) | Full build (`full_build` selector) into `pr_<N>` — no defer needed; sources come from `LH_source` |
| `generate_schema_name` (or any macro) changed in a PR | `state:modified` flags all dependent models once → one-time full build in that PR's schema; expected |
| A merge to `dev` breaks the build | The baseline stays at the last successful `build-dev` run (CI downloads the latest *successful* run), so PRs keep working while dev is red — but they are validated against an older baseline until it is fixed |
| PR opened while `build-dev` is still running | Compared against the previous baseline: over-selects (more nodes look modified), never under-selects. Harmless |
| Artifact retention (90 days default) | Every merge to `dev` refreshes it; an idle repo degrades safely to full builds |
| Unmodified model already built by an earlier push of the same PR | dbt prefers the existing `pr_<N>` relation over the baseline one; harmless within one PR. `--favor-state` would force the baseline deterministically — optional, not enabled |
| Column added to a bronze model | Rebuilt in `pr_<N>` if selected; otherwise read from the baseline, which `build-dev` rebuilt from the same commit range. Silver `ads` models carry `+on_schema_change: sync_all_columns` so the column also reaches existing incremental tables |

## State comparison and the behavior flag

PR-scoped schemas change every node's **rendered** schema, and
`state:modified` compares relation values — without countermeasures every model
would always look modified and slim CI would silently become a permanent full
build. [`dbt_project.yml`](../dbt_project.yml) therefore sets:

```yaml
flags:
  state_modified_compare_more_unrendered_values: true
```

With this flag dbt compares the **unrendered** `+schema:` configs (identical on
both sides) instead of the rendered schema names. Keep it in place — removing
it re-breaks slim CI without any error message.

## CI cost guard

[`macros/limit_ci_rows.sql`](../macros/limit_ci_rows.sql) emits a
`WHERE <column> >= DATEADD(DAY, -<days>, SYSUTCDATETIME())` clause **only on
the ci target** (and renders to nothing everywhere else, including under
sqlfluff). Apply it selectively to large models, e.g.
[`stg_sales__order_lines`](../models/bronze/staging/sales/stg_sales__order_lines.sql):

```sql
FROM {{ source('sales', 'raw_sales_order_lines') }}
{{ limit_ci_rows('updated_at', 30) }}
```

Rules:

- Only filter **child/fact-grain** models (order lines, events, transactions).
  Filtering the *parent* side of a `relationships` test would orphan child rows
  and fail the test run.
- Do not blanket-apply it; CI should still exercise realistic joins. Add it
  model by model when CI build time or capacity cost becomes noticeable.
