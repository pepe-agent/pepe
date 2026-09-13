---
title: Insight
description: Train small local prediction, clustering, anomaly-detection, and forecasting models over your own data, so a repeated question gets answered instantly and for free instead of reasoning from scratch every time.
---

The `insight` tool lets an agent turn your own verified data into a small model it trains
and keeps, so a specific, repeated question ("will this patient deteriorate", "will this
lead convert", "how many next week") gets answered instantly, without a model call, once
there's enough history to learn from. Pepe picks the algorithm automatically, based on how
much data actually exists; nothing to configure, nothing to tune.

This is not general machine learning research. It answers one question you define, from
data you already have: a real, bounded capability, not open-ended discovery.

## Four kinds of question

- **Classification**: predict a category. *Will this patient be readmitted within 30
  days?*
- **Regression**: predict a number. *How many days will this patient likely stay
  admitted?*
- **Forecast**: predict a number **over time**. *How many admissions next week, based on
  the trend so far?*
- **Clustering**: group similar rows together, with no target at all. *What patient
  profiles exist in this data, and which patient doesn't fit any of them?*

Clustering doubles as anomaly detection for free: a row far from every group's usual
spread comes back flagged, the same model that did the grouping. A patient whose vitals
put them nowhere near their usual peer group is exactly that kind of anomaly, worth a
look before it becomes an emergency.

## Where the data comes from

Two sources, chosen when you define what to predict:

- **A registered database connection**: the same ones `db_query`/`manage_db` already use,
  Postgres, tenant-isolated by Row-Level Security if configured. See [Database](/docs/database).
- **Imported rows**: hand rows in directly with `import_rows`. This is the path for
  anything Pepe has no native connector for. An agent reads a file, queries a different
  database engine via `bash` (see [Database](/docs/database) for the RLS caveat, which
  doesn't apply outside Postgres), or pulls from an API, and feeds the resulting rows in.
  Both sources train through the exact same pipeline; the algorithm never knows which one
  a given spec uses.

## Not sure what to predict yet?

Ask to "analyze my data for insights" and, for a database connection, `insight
propose_targets` samples real rows and suggests candidate target columns: a low-cardinality
column is a plausible category to classify, a numeric column with real spread is something
to regress on, a name like `status`/`risk`/`churn` counts in its favor. It's a heuristic,
not a guarantee, and it never defines anything on its own - it's a starting point to
confirm, not a finished spec.

## Defining what to predict

There's no separate syntax to learn: describe what you want in the conversation, and the
agent fills in the actual `insight define` call. For a classification/regression spec,
name the target and which columns to predict it from: "predict whether a patient gets
readmitted within 30 days, using age, length of stay, and prior admissions, from the
`discharges` table in `patients_prod`." A forecast spec names a time column instead of (or
alongside) other columns: "forecast daily admission counts over the `day` column." A
clustering spec names no target at all, just what to group on: "group patients by age,
comorbidity count, and prior admissions."

Then `insight import_rows` (for an imported spec) or `insight train_now` (for either kind)
once there's enough history, and `insight_predict` for an answer, for the list of what's
defined, and for a spec's model history. It's a separate tool on purpose - `insight`
(define/import_rows/train_now/delete) is the one that changes anything; `insight_predict`
(predict/list/describe) only ever reads. That split means an operator can let an unattended surface (a
cron job, a webhook) answer predictions on its own without also handing it the power to
redefine or retrain what it's predicting from.

## How Pepe picks the algorithm

By default, never a manual choice: the model is picked from how much verified data
actually exists, the same "figure it out" philosophy behind [complexity-based
routing](/docs/routing):

- **A few hundred to a couple thousand rows**: simple regression. Fast, robust, no
  overfitting risk on small data. A clinic with a few hundred discharge records gets a
  working model instantly.
- **A couple thousand to tens of thousands of rows**: gradient-boosted trees (XGBoost),
  the strongest general default for this kind of data at the scale most operators actually
  have.
- **Tens of thousands of rows and up**: a small neural network (JIT-compiled via EXLA
  where available), reserved for operators with genuinely large history (hundreds of
  millions of patient events, for instance), enough data for that complexity to earn its
  keep.

A forecast is a regression underneath, with the timestamp turned into elapsed-time and
day-of-week/month features automatically; the same three tiers apply. A model this large
never trains on every row of a huge table: training uses a representative random sample
(Postgres `TABLESAMPLE`, not just "the first N rows", which would bias toward however the
table happens to be ordered), capped at 200,000 rows. Past a certain point, more rows stop
meaningfully improving a model this size.

An operator who already knows which algorithm they want can name it explicitly with
`define`'s `family` ("linear", "gbm", or "neural") instead of leaving it automatic -
useful if they've already benchmarked their own data, or just want the one they're used
to. Leave it unset unless asked; automatic is the right default for almost everyone.

## Retraining

Set `retrain_interval_s` on a spec and Pepe retrains it on its own once enough new rows
have arrived (`min_new_rows`, default 50). A patient-risk model gets sharper as more
discharges are recorded, without anyone re-running anything by hand. `insight train_now`
retrains immediately regardless.

## What it doesn't do

Every model answers one question, defined up front, from structured data with numeric
columns. It does not read free text (a discharge summary, a PDF chart); that data has to
be turned into columns before Insight can use it. It doesn't do time series with anything
beyond a trend and weekly/yearly seasonality, and it doesn't do image or audio. If a
question needs judgment rather than a pattern in past data, that's what the agent itself,
reasoning turn by turn, is for.
