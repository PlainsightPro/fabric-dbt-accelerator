---
name: dbt-documentation
description: >
  Use when writing or reviewing dbt documentation — model, source, and column
  descriptions in _models.yml / _sources.yml, reusable docs blocks and doc()
  references, ownership metadata, PII flagging, exposures for Power BI and other
  downstream consumers, and dbt docs generate workflows. Applies Plainsight's
  documentation minimum standards and definition of done.
---

# dbt Documentation

Source of truth: [`docs/technical-guidelines/dbt/documentation.md`](../../../docs/technical-guidelines/dbt/documentation.md)

**Document the model at the same time you build it.** Docs are part of the contract for
downstream consumers (BI, data apps, ML), not a follow-up task.

## Do / Don't

| Do | Don't |
|---|---|
| Co-locate docs with models/sources in the same folder | Write docs in a separate, rarely updated file |
| Use `doc()` references to reuse canonical text | Duplicate long descriptions across many YAML files |
| Declare owners and downstream exposures | Publish assets without ownership or consumers |
| Describe the business meaning | Write "String" or "ID" without context |
| Regenerate docs in CI | Let docs drift from the manifest/catalog |

## Minimum standards

- **Models** — description states business purpose, grain, refresh expectation, and SLA
  notes where applicable.
- **Sources** — description, owner, freshness, and at least `not_null`/`unique` on keys.
- **Columns** — business meaning, units, valid ranges. **Flag PII/SPI columns explicitly.**
- **Ownership** — every model and source carries an `owner` or `team` field.
- **Contracts** — `constraints`/`tests` sit alongside the docs so description and
  enforcement stay aligned.

Keep `_models.yml` and `_sources.yml` in each folder (staging, intermediate, ADS, gold).

## Docs blocks

Use `{% docs %}` for concepts reused across models — definitions, KPIs, governance notes.
Keep each block short and business-facing.

```sql
{% docs customer_status %}
Customer status reflects the latest lifecycle state. Possible values: `prospect`,
`active`, `churned`. Applied after survivorship rules in `ads_customer`.
{% enddocs %}
```

```yaml
models:
  - name: ads_customer
    description: "Harmonized customer entity, one row per customer. Refreshed daily."
    columns:
      - name: customer_id
        description: "Persistent surrogate key for the customer entity"
        tests: [not_null, unique]
      - name: status
        description: "{{ doc('customer_status') }}"
      - name: first_order_date
        description: "Date of first successful order (UTC)"
```

- Doc block names are references — **don't rename without updating every `doc()` call**.
- Use `doc()` for repeated business terms, not for one-off descriptions.
- Keep blocks portable: no adapter-specific templating inside them.

## Exposures

Declare Power BI reports, semantic models, notebooks, and scheduled jobs as exposures so
lineage reflects true consumers. Exposures are not just documentation — the `exposure:`
selector lets orchestrators target exactly what a consumer needs (see `dbt-run-and-selectors`).

```yaml
exposures:
  - name: sales_exec_dashboard
    type: dashboard
    maturity: high
    url: https://app.powerbi.com/groups/<workspace>/reports/<report_id>
    owner:
      name: Sales Analytics
      email: analytics@example.com
    depends_on:
      - ref('f_sales')
      - ref('d_customer')
    description: "Executive view of revenue, pipeline, and retention metrics."
```

Always include `url`, `owner`, and `maturity`, and capture critical facts/dimensions in
`depends_on` so impact analysis works. Keep the definition adapter-agnostic — secrets live
in the consuming platform, never in dbt. **Exposure names become orchestrator contracts;
keep them stable once referenced.**

## Generation workflow

```sh
dbt docs generate --target prod
dbt docs serve --port 8080 --no-browser
```

- Regenerate docs on every PR that touches models or sources; fail CI when undocumented
  models or columns are introduced.
- Publish `target/manifest.json` and `target/catalog.json` to the agreed wiki/storage
  location. **Never commit the `target/` folder.**
- If hosting the HTML, keep it outside the repo and note the publish location in the dbt
  project's README.

## Definition of done

- [ ] Every new/changed model and source has a description covering purpose, grain, and
      refresh expectations.
- [ ] All new columns carry business-meaningful descriptions; PII/SPI flagged.
- [ ] Ownership (team/email) set for models and sources.
- [ ] Applicable tests added and aligned with the descriptions.
- [ ] Exposures updated or added for any new downstream consumer.
- [ ] `dbt docs generate` runs cleanly with no undocumented items; artifacts published.
