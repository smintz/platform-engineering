# The SLI menu, and how to implement one

Read this when choosing what to measure for a specific service, or when you have a
specification and need a query that computes it.

## Contents

- Specification versus implementation
- Request-driven services
- Pipelines
- Storage
- Where to measure, and what each vantage point misses
- Worked implementations (PromQL, CloudWatch Metrics Insights, SQL)
- Denominators: the part that is actually hard

## Specification versus implementation

Two different artifacts, and conflating them is why SLO discussions stall:

- **Specification** — "the assessment of service outcome that you think matters to users,
  independent of how it is measured". Written in a sentence, agreed with the people who
  care, and stable for years.
- **Implementation** — "the SLI specification and a way to measure it". Changes whenever
  the telemetry changes, and is always a compromise.

Write the specification first and keep it in the objective's description. When someone
later asks "why is this query shaped like that?", the specification is the answer.

## Request-driven services

| Indicator | Specification shape | Typical implementation |
|---|---|---|
| Availability | Share of valid requests served successfully | Non-5xx responses / all responses, at the load balancer |
| Latency | Share of valid requests served faster than a threshold | Histogram bucket ≤ threshold / total count |
| Quality | Share of requests served without degradation | Requests not served from a fallback / total, needs app instrumentation |

Latency deserves two objectives, not one percentile: a tight threshold at a loose target
(90% under 100ms) and a loose threshold at a tight target (99% under 1s). Together they
describe the distribution; a single p99 tells you nothing about what most users saw, and
an *average* actively hides the tail — 5% of requests being 20 times slower is invisible
in a mean.

## Pipelines

A pipeline's users are downstream: another system, a report, a trading model. They notice
lateness and gaps, not the pipeline's internal health.

| Indicator | Specification shape | Notes |
|---|---|---|
| Freshness | Share of data updated more recently than a threshold | Or: share of time the newest record was younger than the threshold |
| Correctness | Share of records with the right output | Needs an independent oracle — see below |
| Coverage (completeness) | Share of records the pipeline was meant to process that it did | The denominator is the expected input, which usually has to be *generated*, not observed |

Spotify's event delivery, quoted in the workbook, is the canonical worked example:
timeliness (max delay for delivering an hourly bucket), completeness (share of published
events actually delivered), and skewness (share of data landing in the wrong bucket) —
audited daily by an *external* system comparing published against delivered counts.

Two habits worth copying:

- **Measure end to end, not per stage.** Every stage can report success while a field is
  silently dropped between them. Per-component objectives miss exactly the failures that
  hurt most.
- **Make correctness independent.** A pipeline that checks its own output cannot detect
  the bug that made it wrong. Inject records with known-good expected output, or reconcile
  against the source of truth.

Prefer stale data over wrong data when the pipeline degrades, and say so in the objective:
freshness missing for an hour is an incident; incorrect rows written for an hour is a
cleanup project.

## Storage

Durability — the share of written records still retrievable — is the objective that
matters and the hardest to measure; it is usually asserted through periodic read-back
audits of a sample. Reads also get availability and latency objectives like any
request-driven service.

## Where to measure, and what each vantage point misses

| Vantage | Sees | Misses |
|---|---|---|
| Client / RUM | What the user actually experienced | Expensive, noisy, only covers instrumented clients |
| Load balancer | All served traffic, cheaply | Failures before the LB; the user's own network |
| Application server | Rich detail, per-endpoint | Requests that never arrived — exactly the worst outages |
| Black-box prober | Whether the service is up from outside | Real traffic patterns; tiny sample |
| Destination datastore | Ground truth about what was written | Says nothing about why, or about latency |

Start with whatever "requires a minimum of engineering work", write down what it misses,
and improve it when a real incident exposes the gap.

## Worked implementations

**Availability, PromQL** — good over valid, 28-day window:

```promql
sum(rate(http_requests_total{job="api",code!~"5.."}[28d]))
  /
sum(rate(http_requests_total{job="api"}[28d]))
```

**Latency, PromQL** — share of requests inside the threshold, not a percentile:

```promql
sum(rate(http_request_duration_seconds_bucket{job="api",le="0.3"}[28d]))
  /
sum(rate(http_request_duration_seconds_count{job="api"}[28d]))
```

**Freshness of a table, SQL** — the *share of the window* the data was fresh, rather than
the age right now. The gauge version (`age of newest row`) is fine as a diagnostic panel,
but this is the version that can be missed by a budget:

```sql
SELECT now() AS time,
       count(*) FILTER (WHERE age <= INTERVAL '2 minutes')::float / count(*) AS freshness
FROM (
    SELECT bucket, now() - max(written_at) AS age
    FROM events
    WHERE written_at > now() - INTERVAL '28 days'
    GROUP BY bucket
) s
```

**Coverage of a pipeline, SQL** — generate the expected input and left-join what arrived.
The generated side is the denominator; this is what makes gaps visible at all:

```sql
WITH expected AS (
    SELECT g AS slot
    FROM generate_series(now() - INTERVAL '28 days', now(), INTERVAL '1 minute') g
    WHERE <slot is one the pipeline was meant to produce>
)
SELECT now() AS time,
       count(a.slot)::float / count(*) AS coverage
FROM expected e
LEFT JOIN arrived a ON a.slot = e.slot
```

**Resource saturation, CloudWatch Metrics Insights** — worth a panel, but this is a cause,
not an objective; it explains a symptom rather than being one:

```sql
SELECT AVG(CPUUtilization) FROM SCHEMA("AWS/RDS", DBClusterIdentifier)
WHERE DBClusterIdentifier = 'my-cluster'
```

## Denominators: the part that is actually hard

Most wrong SLIs are wrong in the denominator.

- **Time-based denominators** count periods when nothing was expected to happen. A weekend
  of zero traffic scores 100% availability, and a market holiday scores 0% coverage. Scope
  the denominator to when the service was supposed to be doing something.
- **Observed denominators** hide the failure you care about. "Rows we processed / rows we
  saw" is 1.0 even when the pipeline never saw half its input. Generate the expected set
  from an independent source — a calendar, a schedule, the upstream's own count.
- **Unscoped denominators** import other people's failures. Requests to endpoints you do
  not own, or clients you cannot fix, make the objective undefendable.

A useful test: describe the denominator out loud as "out of all the times we *should* have
been good". If that sentence needs a caveat, the query needs the caveat too.
