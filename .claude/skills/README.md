# Plainsight dbt Skill Pack

Agent Skills that encode the dbt guidance from
[`docs/technical-guidelines/dbt/`](../../docs/technical-guidelines/dbt/) so Claude Code
applies Plainsight's conventions automatically instead of needing them re-explained in
every session.

Skills follow the open [Agent Skills](https://github.com/vercel-labs/skills) `SKILL.md`
standard, so the same files work in Claude Code, Cursor, Codex, and other supporting tools.

## What's here

| Skill | Triggers when you're… | Playbook page |
|---|---|---|
| [`dbt-project-structure`](dbt-project-structure/SKILL.md) | Placing, naming, or moving a model; setting layer defaults | [Project Structure](../../docs/technical-guidelines/dbt/project-structure.md) |
| [`dbt-sql-style`](dbt-sql-style/SKILL.md) | Writing a model's SQL body, a macro, or Jinja | [SQL Style & Configuration](../../docs/technical-guidelines/dbt/sql-style-and-configuration.md) |
| [`dbt-testing`](dbt-testing/SKILL.md) | Adding, reviewing, or debugging tests and freshness | [Operations & Testing](../../docs/technical-guidelines/dbt/operations-and-testing.md) |
| [`dbt-documentation`](dbt-documentation/SKILL.md) | Writing descriptions, docs blocks, or exposures | [Documentation](../../docs/technical-guidelines/dbt/documentation.md) |
| [`dbt-run-and-selectors`](dbt-run-and-selectors/SKILL.md) | Choosing run commands, selectors, or orchestration config | [Operations & Testing](../../docs/technical-guidelines/dbt/operations-and-testing.md) |
| [`dbt-tooling-setup`](dbt-tooling-setup/SKILL.md) | Onboarding, configuring SQLFluff, pinning packages | [Third-Party Tooling](../../docs/technical-guidelines/dbt/third-party-tooling.md) |
| [`dbt-model-review`](dbt-model-review/SKILL.md) | Reviewing a dbt PR — run it explicitly with `/dbt-model-review` | all of the above |

The first six trigger automatically from their descriptions. `dbt-model-review` is meant to
be invoked on demand.

## Using them in a dbt project

These skills live here so they're versioned and reviewed alongside the playbook they encode.
To use them in an actual dbt repo, copy the folders across:

```sh
mkdir -p <your-dbt-project>/.claude/skills
cp -r .claude/skills/dbt-* <your-dbt-project>/.claude/skills/
```

Commit them in the target repo so the whole team gets the same behavior. The links back to
playbook pages become dead once copied out — that's fine, the skill bodies are self-contained;
the links are provenance for whoever maintains them.

## Layer these with dbt Labs' official skills

dbt Labs publishes [`dbt-labs/dbt-agent-skills`](https://github.com/dbt-labs/dbt-agent-skills) —
general dbt best practices maintained by the people who build dbt. They compose with this
pack rather than competing with it:

```
Plainsight skills (this pack)   ← our layering, naming, coverage matrix, review gate
        ↓
dbt Labs skills                 ← general dbt workflow, CLI, semantic layer, mesh
        ↓
Coding agent
```

Install in Claude Code:

```
/plugin marketplace add dbt-labs/dbt-agent-skills
/plugin install dbt@dbt-agent-marketplace
/plugin install dbt-migration@dbt-agent-marketplace     # migrations, one-off use
```

Or, for any agent (needs Node.js):

```sh
npx skills add dbt-labs/dbt-agent-skills --global
npx skills add dbt-labs/dbt-agent-skills --skill using-dbt-for-analytics-engineering
```

Restart your terminal afterwards so the new skills are detected.

### What dbt Labs covers

| Skill | Purpose |
|---|---|
| `using-dbt-for-analytics-engineering` | The main one — build and modify models, debug errors, explore sources, write tests |
| `running-dbt-commands` | Correct CLI flags, selectors, and parameter formats |
| `adding-dbt-unit-test` | Unit tests and test-driven development for models |
| `building-dbt-semantic-layer` | Semantic models, metrics, and dimensions with MetricFlow |
| `answering-natural-language-questions-with-dbt` | Query the semantic layer to answer business questions |
| `working-with-dbt-mesh` | Contracts, access, groups, versions, cross-project collaboration |
| `troubleshooting-dbt-job-errors` | Diagnose dbt platform job failures |
| `configuring-dbt-mcp-server` | Set up the dbt MCP server for Claude, Cursor, or VS Code |
| `fetching-dbt-docs` | Look up dbt documentation efficiently |
| `migrating-dbt-core-to-fusion` | Move a project from dbt Core to the Fusion engine |
| `migrating-dbt-project-across-platforms` | Move a project across data platforms |

**Precedence:** where the two disagree, Plainsight's conventions win — our layer names
(`bronze/silver/gold`, `ads_`, `lnd_`) and coverage matrix are deliberate departures from
the generic dbt-labs `staging/intermediate/marts` shape.

## Maintaining this pack

Skills are instructions that silently shape output across every project that installs them.
Treat changes like code changes:

- Update the skill in the same PR as the playbook page it encodes — they must not drift.
- Keep descriptions specific about **technology, action, and scope**. A vague description
  triggers unpredictably; see the playbook's
  [Claude Code Extensibility Guide](../../docs/technical-guidelines/plainsight-ai/agentic-development/skills.md)
  for the description-writing checklist.
- One concern per skill. If a skill grows to cover "all dbt things", split it.
- Verify with `/skills` in a Claude Code session that all seven are discovered.

## Sources

- [dbt-labs/dbt-agent-skills](https://github.com/dbt-labs/dbt-agent-skills)
- [Make your AI better at data work with dbt's agent skills](https://docs.getdbt.com/blog/dbt-agent-skills)
- [Agent Skills standard (vercel-labs/skills)](https://github.com/vercel-labs/skills)
