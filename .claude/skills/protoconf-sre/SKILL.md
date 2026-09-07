---
name: sre
description: Define, review, and encode service level objectives (SLOs) and their indicators the way Google's SRE book and workbook teach — pick the right SLI for the system type, express it as good events over valid events across a window, set an achievable target, and write it into a Protoconf component (`WithSLO`, objectives, Grafana dashboards). Use this whenever the user mentions SLO, SLI, SLA, error budget, burn rate, reliability targets, "what should we alert on", availability/latency/freshness/completeness targets, or asks to add monitoring or a dashboard to a service or component — and also when a user is writing an objective, threshold, or alert condition without naming it an SLO, because the failure mode there is usually a metric that measures a cause instead of a user-visible symptom. In a Protoconf repository, use this together with the protoconf-dev skill: this one decides what to measure, protoconf-dev covers the Starlark and proto mechanics.
---

# Defining SLOs

An SLO is a promise about how often a service is allowed to be bad, stated in terms a user would recognise. Most bad SLOs fail before any query is written — they measure something the team can see (CPU, restarts, queue depth) rather than something the user feels (their request failed, their data is late). Everything below exists to get the definition right first, then encode it.

## The vocabulary, and why the distinction earns its keep

- **SLI** — "a carefully defined quantitative measure of some aspect of the level of service that is provided". A number between 0 and 1: *good events / valid events*.
- **SLO** — "a target value or range of values for a service level that is measured by an SLI", over a stated window. `SLI ≥ 99.9% over 28 days`.
- **SLA** — an SLO with consequences (refunds, penalties) attached. Internal services rarely need one; if breaching costs money, it is an SLA.
- **Error budget** — `100% − SLO`. A 99.9% target over 28 days buys ~40 minutes of badness. This is the point of the whole exercise: it converts "is the service reliable enough?" from an argument into arithmetic, and it gives the team permission to spend that budget on releases instead of hoarding it.

100% is the wrong target. It is unachievable end to end, it forbids maintenance, and users cannot tell the difference between 100% and 99.99% through their own network anyway.

## The workflow

Work in this order. Skipping to step 4 is what produces dashboards nobody trusts.

**1. Name the users and what they'd complain about.** Who consumes this thing, and what does a bad day look like *to them*? For a pipeline the user is usually the next system or a person reading a report — "the data is hours stale", "yesterday's rows are missing", not "the task restarted".

**2. Pick indicators from the menu for the system type.** Most systems are one of three shapes, and each has a small standard set. Full menu with worked examples in `references/sli-menu.md`:

| System type | Indicators that matter |
|---|---|
| Request-driven (an API, a web app) | **Availability** — share of requests served successfully. **Latency** — share served faster than a threshold. **Quality** — share served undegraded. |
| Pipeline (ingest → transform → write) | **Freshness** — share of data updated more recently than a threshold. **Correctness** — share of records with the right output. **Coverage** — share of records actually processed. |
| Storage | **Durability** — share of written records still retrievable. Plus latency and availability of reads. |

Two or three per service is plenty. Every SLO is something a human must defend at 3am; a dashboard of twenty is a dashboard nobody reads.

**3. Write the specification in a sentence, before any query.** The specification is the outcome you care about, independent of measurement: *"99% of minute bars for actively traded symbols are written within 2 minutes of the minute closing."* Then choose the implementation — where that can actually be measured. The same specification measured at the client, the load balancer, the server, or the destination database gives different numbers, different coverage and different cost. Say which one you picked and what it misses; a proxy you understand beats a perfect metric you cannot collect.

**4. Express it as a ratio over a window.** This is the step people skip, and it is what separates an SLO from a gauge on a dashboard:

```
SLI = good events / valid events, over the last N days
```

*Valid events* is the denominator that scopes the promise — requests to endpoints you own, minutes the market was open, records the pipeline was meant to see. Getting the denominator right is most of the work: it is what stops a quiet weekend from looking like perfect reliability, and what stops a holiday from looking like an outage.

A raw gauge (`p99 latency`, `age of newest row`, `CPU utilisation`) is an *indicator*, not an objective. It is useful on a dashboard and it is the raw material for the ratio, but "p99 < 300ms right now" cannot be missed by a budget, cannot be traded against release velocity, and answers no question about the last month. When a repo's objective model is a query plus a bound, prefer the query that computes the compliance ratio and set the bound to the target. Keep gauges too if they aid diagnosis, but know which of the two you are writing, and check
that the tooling can tell them apart before promising to "keep the panel, drop the
objective" — in most repos the objective list *is* the dashboard, so demoting one deletes
it. `references/protoconf-slos.md` covers the options.

**5. Set the target from history, rounded down, and never at 100%.** Measure what the service actually did over the last few weeks, then round to something defensible: two significant figures for availability, 50ms steps for latency. If nobody has been measuring, ship the SLI first and set the target after a few weeks of data — a made-up number that fires constantly gets muted, and a muted SLO is worse than none. Use a **28-day rolling window** unless there is a reason not to: it covers four weekends, matches how users remember recent experience, and doesn't reset on the 1st of the month.

Multiple thresholds beat one for latency: 90% under 100ms *and* 99% under 1s describes the shape of the distribution in a way any single percentile cannot. Never average latency — an average hides the tail that is actually hurting people.

**6. Encode it, then check it moves.** In a Protoconf repo, objectives are declared on the component and rendered by a dashboard driver — see `references/protoconf-slos.md` for `WithSLO`, units, severities, datasource kinds, and how to add one. Then verify: a healthy service should score at or just above the target, a total outage should score 0, and a partial one should land in between. A query that reads 1.0 through a known incident is measuring the wrong thing.

## Alerting comes from the budget, not from the threshold

Once an SLO exists, alert on **burn rate** — how fast the incident is eating the error budget — not on the raw metric crossing a line. A 14.4x burn rate over an hour has spent 2% of a 28-day budget and deserves a page; a 1x burn over three days deserves a ticket. This is what makes an alert both urgent and worth waking someone for, and it scales the response to the severity automatically. The recommended windows and multipliers are in `references/alerting-on-slos.md`.

Page only on symptoms that are urgent, actionable, and user-visible. Cause metrics (saturation, restarts, queue depth) belong on dashboards and in tickets, where they explain a symptom that already fired.

## Reviewing an SLO someone already wrote

Ask these in order; the first "no" is usually the whole problem:

1. **Would a user notice when this breaks?** If it measures a cause — CPU, memory, replica count, restarts — it is a monitoring signal, not an objective. Keep it, label it as such, and find the symptom it causes.
2. **Is it a ratio over a window, or an instantaneous gauge?** If it cannot be missed by 0.1% over a month, it cannot have an error budget.
3. **What is in the denominator?** Does it include periods when the service was not meant to be doing anything? Does it exclude traffic you are responsible for?
4. **Would it survive a normal week?** Holidays, deploys, market closures, empty weekends. An objective that cries wolf every third Monday is already dead.
5. **Is the target justified by data, and is it under 100%?**
6. **Is the measurement independent of the thing being measured?** A pipeline that validates its own output cannot detect that it dropped records. Correctness usually needs injected known-good data or an external audit.
7. **Could you defend it in a review?** Product owner, developer, and whoever carries the pager all have to accept it — including what happens when the budget runs out.

## Where the depth lives

- `references/sli-menu.md` — the menu by system type, specification-versus-implementation, and worked SLI implementations (PromQL, CloudWatch Metrics Insights, SQL) including the pipeline case in detail.
- `references/alerting-on-slos.md` — burn-rate math, the recommended multiwindow parameters, and how to derive alert rules from an objective.
- `references/protoconf-slos.md` — how objectives are declared, rendered, and extended in a Protoconf component repo; the mechanical traps (proto3 zero bounds, unit enums, datasource kinds, dashboard rendering order).

Sources: Google SRE book ch. 4 (Service Level Objectives) and ch. 6 (Monitoring Distributed Systems); SRE workbook ch. 2 (Implementing SLOs), ch. 5 (Alerting on SLOs), and ch. 13 (Data Processing Pipelines).
