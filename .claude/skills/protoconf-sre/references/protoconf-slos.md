# Encoding objectives in a Protoconf component repo

Read this once you know *what* to measure and need to write it down. For the Starlark and
proto mechanics themselves — hook chains, `load()` paths, the compile loop — use the
**protoconf-dev** skill; this file only covers the objective-specific parts.

## Find the local shape first

Repos differ. Before writing anything, look at what already exists:

```bash
grep -rn "WithSLO\|Objective" src/ --include=*.pinc --include=*.proto | head -20
```

Read one existing objective end to end — the declaration, the proto that types it, and the
driver that renders it. Copy that shape. The rest of this file describes the pattern these
repos converge on, so you can recognise it quickly.

## The pattern

Objectives are declared **on the component**, not in the dashboard. The component says what
it promises; a monitoring driver renders that into whatever tool the organisation uses.
That separation is the point: swapping Grafana for something else should not touch a single
component, and a component should not know that dashboards exist.

```python
platform.WithSLO(
    "minute bar freshness",
    QUERY,
    description="Age of the newest NVDA minute bar; the feed is a minute apart, so minutes behind means we are losing bars",
    datasource="postgres",
    max=180.0,
    unit=platform.Unit.UNIT_SECONDS,
    severity=platform.Status.STATUS_CRIT,
)
```

The fields, and what they are for:

| Field | Meaning |
|---|---|
| `name` | Short, lowercase, reads as a noun phrase on a panel: "minute bar freshness", "write latency" |
| `query` | The SLI, in the query language of `datasource` |
| `description` | Where the **specification** goes — the user-visible outcome and why the bound is where it is. This is the field that survives a handover |
| `datasource` | Which kind of datasource answers the query (`prometheus`, `cloudwatch`, `postgres`, …) |
| `min` / `max` | The bound. A ratio objective sets `min` to the target; a gauge sets `max` to the ceiling |
| `unit` | What the number means, so whoever renders it can label an axis: `UNIT_RATIO`, `UNIT_PERCENT`, `UNIT_SECONDS`, `UNIT_MILLISECONDS`, `UNIT_BYTES`, `UNIT_COUNT` |
| `severity` | `STATUS_WARN` by default; `STATUS_CRIT` for the ones that mean the service is not doing its job |

## Query language per datasource kind

The kind selects both the datasource and how the query is spelled. Getting this wrong
produces a panel that renders but never returns data:

- **`prometheus`** — a PromQL expression. Rendered into the panel's `expr`.
- **`cloudwatch`** — Metrics Insights SQL (`SELECT AVG(x) FROM SCHEMA(...)`), rendered into
  `sqlExpression` with the metrics-insights mode flags. Not metric math, which is a
  different field entirely.
- **`postgres`** (or any SQL datasource) — the statement itself, rendered into `rawSql`.
  Grafana's `time_series` format needs a column literally named `time`, so these queries
  start `SELECT now() AS time, …`.

Adding a new kind is usually three edits: teach the monitoring driver how to spell a query
for it (a branch in whatever builds the panel target), add any proto fields that target
shape needs, and add the datasource's name to the map the caller passes in. The name of an
organisation's datasource belongs to the caller, not the driver — the driver knows how to
speak to a kind of datasource and nothing about what anyone called theirs.

## Where a demoted gauge goes

Reviewing usually produces the conclusion "this is a cause, not an objective — keep the
panel, drop the objective". Check whether the repo can actually express that before
promising it. In the common shape, the objective list is the *only* input to the dashboard
and the driver renders one panel per objective of type `TYPE_SLO`, so deleting the
objective deletes the panel too, and the responder loses the context that explains the
page.

Three honest options, in order of preference:

1. **Give the model a diagnostic kind.** If the objective proto has a `type` enum
   (`TYPE_SLO`, `TYPE_RPO`, `TYPE_RTO`, …), add one for diagnostics and have the driver
   render it in its own row without a threshold. Now the distinction is in the data, and
   nothing else has to remember it.
2. **Keep it as an objective, with the description doing the work.** Cheapest, and honest
   as long as the description says plainly that it is a saturation signal explaining
   another objective — not something anyone should page on.
3. **Move it to a hand-maintained dashboard.** Only if the repo already has one; a second
   place to edit dashboards is a cost that outlives the cleanup.

Say which one you took. Silently deleting a panel because it failed a definition is how
review advice gets a bad name.

## Mechanical traps

- **Proto3 zeroes read as unset.** `min=0.0` and `max=0.0` are indistinguishable from "no
  bound", so an objective that legitimately bounds at zero ("zero dropped records") needs a
  different shape — invert it into a ratio, or bound the complement.
- **Ratios are 0–1, percentages are 0–100.** Pick the unit that matches what the query
  actually returns. `UNIT_RATIO` renders as `percentunit` in Grafana and will silently show
  99.9% as 9990% if the query already multiplied by 100.
- **The dashboard is rendered from the finished component.** The driver runs as a finalizer,
  after dependencies are wired, because it is a *view* of what was declared. An objective
  added by a hook that runs mid-chain still lands, but anything reading the objective list
  earlier will see half of it.
- **Objectives usually render into their own state**, separate from the one that provisions
  the component, so a broken dashboard can never block an infrastructure apply — and so the
  monitoring provider's credentials stay out of the infrastructure state.
- **These queries run on every dashboard refresh.** Panels typically refresh every minute,
  so an SLI that scans 28 days of a large table each time is a load problem the day someone
  leaves the dashboard open. Prometheus handles long ranges well; SQL over a partitioned
  fact table often does not. Keep the window predicate on the partition key, and if the
  query still costs real time, precompute it — a materialized rollup the pipeline refreshes,
  queried cheaply by the panel, is both faster and a more stable measurement.
- **A component with no objectives renders no dashboard.** If a dashboard did not appear,
  check that the objectives are actually on the component the driver ran against.

## Verify before committing

```bash
make            # or: protoconf compile .
```

Then read the generated monitoring output — the panels, their queries, their bounds and
units:

```bash
python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
cfg=json.loads(d['resource']['grafana_dashboard']['slos']['config_json'])
for p in cfg['panels']:
    dflt=p['fieldConfig']['defaults']
    print('--', p['title'], '|', p['datasource']['type'], '| min', dflt.get('min'), 'max', dflt.get('max'), '|', dflt.get('unit'))
    t=p['targets'][0]
    print(t.get('expr') or t.get('rawSql') or t.get('sqlExpression'))
" outputs/components/<domain>/<component>/monitoring/main.tf.json
```

Reading the rendered query back is worth the thirty seconds: it catches the unit mismatch,
the bound that landed on the wrong field, and the query that got mangled by string
formatting. What it cannot catch is whether the query returns what you think — run it
against the real datasource before trusting the panel, and confirm the number moves the way
you expect during a known-bad period.
