# Slim CI architecture

How pull-request validation builds only what changed, in full isolation, while
reading everything unchanged from a stable baseline. Pipeline setup lives in
[`cicd/README.md`](../cicd/README.md); this document explains the design.

## The one command

```bash
dbt build --target ci --selector ci_modified --state state_dev --defer --defer-state state_accept
```

Two manifests, two strictly separated roles:

| Manifest artifact     | Produced by     | Compiled with      | Role | Flag |
| --------------------- | --------------- | ------------------ | ---- | ---- |
| `dbt-manifest-dev`    | `build-dev` (merge to `dev`)       | `--target ci`     | **Selection** — which nodes count as *modified* vs. the `dev` branch | `--state state_dev` |
| `dbt-manifest-accept` | `deploy-accept` (merge to `accept`) | `--target accept` | **Defer** — where refs to *unmodified* nodes resolve to | `--defer-state state_accept` |

The `ci_modified` selector ([`selectors.yml`](../selectors.yml)) picks
`modified+`: everything that changed relative to the dev manifest, plus
downstream dependents. Those nodes are built into the PR's own schema (below).
Every `ref()` to a node **not** selected resolves to the location recorded in
the accept manifest — `<ACCEPT_DB>.<layer schema>.<table>` — i.e. the accept
warehouse, a baseline that only promotion merges ever change.

**Never point `--defer-state` at the dev- or ci-compiled manifest.** That
manifest records CI-warehouse locations, so deferred refs would read whatever
some other PR last built there — the exact cross-PR contamination this design
removes.

## ⚠️ Workspace colocation requirement (infra prerequisite)

Deferred refs compile to three-part names (`<ACCEPT_DB>.<schema>.<table>`).
**Fabric only allows cross-database queries between items in the SAME
workspace.** Therefore:

> The **CI warehouse**, the **accept warehouse**, and the **`LH_source`
> lakehouse** (declared as `database:` in the `_sources.yml` files) must all
> live in **one Fabric workspace**, and the CI service principal needs read
> access to the accept warehouse.

This cannot be enforced from code. The `ci` pipeline runs a smoke test before
building — `dbt run-operation assert_cross_db_access` probing
`SELECT TOP 1 1 FROM [<ACCEPT_DB>].INFORMATION_SCHEMA.TABLES` (the accept DB
name is taken from the downloaded manifest, so no extra pipeline variable is
needed) — and fails fast with a colocation hint if the read is not possible.

## PR schema lifecycle

`generate_schema_name` ([`macros/generate_schema_name.sql`](../macros/generate_schema_name.sql))
routes **all** models of a CI run into one flat schema `pr_<PR number>` when
`DBT_CI_SCHEMA_SUFFIX` is set (the pipelines set it from the PR number; when it
is unset — local `--target ci` runs, `build-dev` — behavior is unchanged).

| Event                | Effect on the CI warehouse |
| -------------------- | -------------------------- |
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
  abandoned — code. Now every PR writes only to `pr_<N>` and reads only from
  accept.
- **Stale / drifting baseline.** The defer target used to be whatever the CI
  workspace happened to contain. Now it is the accept warehouse, rebuilt by
  the Fabric runtime from promoted code on a fixed cadence.
- **Concurrent-run interference.** Per-PR concurrency groups
  (cancel-in-progress) plus per-PR schemas make simultaneous runs of different
  PRs fully independent, and repeated pushes to one PR idempotent.

## Fallbacks and edge cases

| Situation | Behavior |
| --------- | -------- |
| `dbt-manifest-accept` missing (first run, expired retention) | Full build (`full_build` selector) into `pr_<N>` — no defer needed; sources come from `LH_source` |
| `dbt-manifest-dev` missing | Same full-build fallback (selection impossible) |
| `generate_schema_name` (or any macro) changed in a PR | `state:modified` flags all dependent models once → one-time full build in that PR's schema; expected |
| Model newly added on `accept` but not yet materialized by the Fabric runtime | Deferred ref may hit a missing relation at runtime — rare at weekly promotion cadence; rerun after the Fabric schedule has caught up |
| Artifact retention (90 days default) | `deploy-accept` runs weekly via promotion, so the artifact stays fresh; an idle repo degrades safely to full builds |
| Unmodified model already built by an earlier push of the same PR | dbt prefers the existing `pr_<N>` relation over the accept one; harmless within one PR. `--favor-state` would force accept deterministically — optional, not enabled |

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
