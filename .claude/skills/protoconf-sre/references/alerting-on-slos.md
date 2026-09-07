# Alerting on SLOs

Read this when turning an objective into something that pages a human, or when someone
asks "what threshold should this alert at?".

## Why not just alert on the threshold

Alerting when the SLI dips below the target sounds right and behaves terribly. At a 99.9%
target evaluated over ten minutes, a single bad minute breaches it — you get dozens of
pages a month while comfortably meeting the objective. Widen the window to fix precision
and the alert now takes 36 hours to clear after the incident is over.

The fix is to alert on **how fast the incident is spending the error budget**, which is
both the thing you actually care about and a number that scales itself to severity.

## Burn rate

Burn rate is error-budget consumption relative to the budget's own pace: at a burn rate of
1, a constant error rate spends the entire budget exactly at the end of the SLO window.

| Burn rate | Budget gone after | What it looks like at a 99.9% SLO |
|---|---|---|
| 1 | the full window | 0.1% of requests failing |
| 2 | half the window | 0.2% failing |
| 10 | ~3 days (of 30) | 1% failing |
| 1,000 | ~43 minutes | total outage |

## The recommended configuration

Multiwindow, multi-burn-rate. The **long window** confirms enough budget has genuinely
been spent to be worth someone's attention; the **short window** (one twelfth of the long
one) confirms the problem is still happening right now, so the alert clears minutes after
the incident ends instead of hours.

For a 99.9% SLO:

| Severity | Long window | Short window | Burn rate | Budget consumed |
|---|---|---|---|---|
| Page | 1 hour | 5 minutes | 14.4 | 2% |
| Page | 6 hours | 30 minutes | 6 | 5% |
| Ticket | 3 days | 6 hours | 1 | 10% |

Both windows must be over threshold for the alert to fire. A total outage trips the first
row within a few minutes; a slow leak that nobody would notice on a graph eventually
raises a ticket rather than a page.

In PromQL, one severity looks like:

```promql
(
  slo:error_ratio:rate1h  > (14.4 * 0.001)
  and
  slo:error_ratio:rate5m  > (14.4 * 0.001)
)
```

Keep these parameters identical across services. Per-service tuning multiplies the number
of things on-call has to reason about at 3am, for a benefit nobody has ever measured.

## What to page on

A page must be urgent, actionable, and about something a user can feel. If the responder's
first action is mechanical, automate it instead of paging. Saturation, restart counts and
queue depth belong on dashboards and in tickets — they explain a symptom that already
fired, and paging on them means being woken for a problem that may never reach a user.

## Low-traffic and very high targets

Two cases where the table above breaks down:

- **Low traffic.** With a handful of events per hour, a single failure swamps the ratio.
  Options: generate synthetic traffic so the denominator is stable, aggregate several
  small services into one objective, or lengthen the windows and accept slower detection.
- **Very high targets** (99.999% and up). The budget can be gone before any alerting
  system reacts. Reliability at that level comes from architecture — redundancy, graceful
  degradation, load shedding — not from faster alerting.

## When the budget runs out

Decide this before the first incident, not during it. An error budget policy states what
changes when the budget is exhausted (typically: releases pause, reliability work takes
priority until the budget recovers), who decides, and how to escalate a disagreement. It
only works if the product owner, the developers, and whoever carries the pager have all
agreed in advance — an unenforced budget is just a chart.
