# Insight - train small local models over your own data

`insight` lets you turn verified history into a model you keep, so a specific repeated
question gets answered instantly and for free next time, instead of you reasoning it out
fresh on every call. By default you do not pick the algorithm: Pepe fits the model size
(and, for `"forecast"`, whether it's a linear/tree/neural regression underneath) to how
much data actually exists. Never mention or promise a specific technique unless the user
asks; your job is defining what to predict, not choosing how. The one exception:
`define`'s optional `family` ("linear", "gbm", or "neural") lets a user who explicitly
names one override the automatic choice - only set it when they actually ask for a
specific algorithm by name, never suggest or default to it yourself. `"neural"` is not
built into every install (the Windows binary has no such tier); if `define` comes back
saying so, tell the user plainly and use `"gbm"` or leave `family` unset. Nothing else
about `insight` changes on such an install.

**Not general ML.** This answers one question, defined up front, from data you already
have. Don't reach for it to "explore the data and see what's interesting" with no target
in mind; that's not what it does.

## The four `task_type`s

- `"classification"`: predicts a category. Needs `target_column`.
- `"regression"`: predicts a number. Needs `target_column`.
- `"forecast"`: predicts a number over time. Needs `target_column` **and** `time_column`
  (a date/timestamp column); `feature_columns` is optional here (a pure time trend needs
  none).
- `"clustering"`: groups rows with no target at all. Needs `feature_columns`, nothing
  else. `predict` on a clustering spec answers with which group a row falls into and
  whether it's an outlier of that group; present that as "this doesn't fit the usual
  pattern for its group," not as a definitive diagnosis.

## Where rows come from

`source_kind: "db"` uses a connection `db_query`/`manage_db` already knows about
(Postgres, tenant-scoped by RLS the same way `db_query` is; see the Database doc, the
same isolation guarantee applies here since `insight` reuses that exact query path). Pick
this whenever the operator already has a `db_query` connection covering the table you need.

`source_kind: "import"` is for anything else: a file the operator gave you, a different
database engine you reached via `bash` (see the `sql-databases` skill: after pulling rows
that way, dump them as objects and call `insight import_rows`), or an API. Define the spec
first, then call `import_rows` with the rows once, and again whenever there's more
history. Rows accumulate; they don't need re-sending each time. `import_rows` caps at
5,000 rows per call (split a bigger batch into several calls) and 50,000 stored examples
per spec (oldest pruned automatically past that).

## Defining a spec

Confirm `target_column`/`time_column`/`feature_columns` names against the actual schema
(e.g. via `db_query`'s connection, or by asking the operator) before calling `define`. A
typo fails later, at `train_now`, with a less obvious error.

For a "db" connection, `propose_targets` (`connection`, optional `table`) samples real
rows and scores candidate target columns by cheap signals (low-cardinality → a category to
classify, real numeric spread → something to regress on, a name like `status`/`risk`/
`churn` boosts the score, an id-looking column is never a candidate). It is a heuristic,
not a guarantee, and it never defines anything itself - show the candidates to the
operator and confirm which one (if any) before calling `define`. If the user just says
"analyze my data for insights" or similar with no specific column in mind, this is the
right first move, not open-ended exploration with `db_query`.

## Training and predicting

`define`/`import_rows`/`train_now`/`delete` are the `insight` tool; `predict`/`list`/
`describe` are the separate `insight_predict` tool - it only ever reads, never changes
anything. If you only have `insight_predict` granted, that's deliberate (an operator
letting you answer predictions without also letting you redefine or retrain the spec) -
don't treat it as a gap to work around.

`train_now` fails clearly if there isn't enough data yet (currently ~20 rows minimum);
say so plainly and suggest importing more, don't retry blindly. `predict` refuses if
nothing has trained yet; call `train_now` first rather than guessing an answer yourself.

Set `retrain_interval_s` + `min_new_rows` on a spec that should keep itself current
automatically; leave both unset for a one-off model you'll retrain by hand with
`train_now` when it matters.

## Explaining results

Report a model's metric honestly (accuracy for classification, rmse for regression/
forecast, silhouette for clustering); don't round it into false confidence. For
clustering, `describe` gives you each group's size and average feature values; use those
to describe a group in plain terms ("older patients with more prior admissions") rather
than just a bare index number.

Risky tool: reading an external database (even to train on it) and persisting a model are
real actions, gated like `manage_db`.
