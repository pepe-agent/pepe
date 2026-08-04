---
title: Database
description: Let an agent read from an external Postgres database, with a customer's own multi-tenancy enforced by the database itself, not by the model.
---

The `db_query` tool lets an agent run a read-only SQL query against an operator-configured
external Postgres database - a customer's own data, not Pepe's internal store. **Postgres
only.** If that database has its own multi-tenancy (a `company_id`-style column separating
one customer's own clients), Pepe binds the trusted tenant value to the connection and never
lets the model see or set it - the actual isolation is enforced by Postgres itself, via Row-Level
Security, not by anything Pepe's own code decides at runtime.

## Why the model never sees the tenant value

A tool argument the model fills in can be gotten wrong - by mistake, or by a page or document
the agent read that told it to use a different value. That is not a redaction miss, it is a
cross-tenant data leak. So `db_query`'s tool spec has no `company_id`/tenant parameter at all:
the model only ever supplies `connection` (a name) and `query` (read-only SQL). The tenant
value comes from configuration set by the operator, resolved server-side, and applied to every
query on that connection automatically.

## Setting up Row-Level Security (do this first)

This is the part Pepe cannot do for you: the operator's own database needs a dedicated,
unprivileged role and a policy. Run something like this once, by hand, on the target database:

```sql
CREATE ROLE pepe_ro LOGIN PASSWORD '...' NOBYPASSRLS;
GRANT SELECT ON orders, invoices TO pepe_ro; -- whatever tables the agent should read

ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON orders
  USING (company_id = current_setting('app.pepe_tenant_id', true)::text);
```

Two things matter here:

- **`NOBYPASSRLS`, and never the table owner.** Superusers and table owners ignore RLS by
  default, even with the policy in place. The role Pepe connects as must be an ordinary,
  unprivileged role for the policy to mean anything.
- **`current_setting('app.pepe_tenant_id', true)`** - this exact GUC name is Pepe's fixed
  convention, not configurable per connection. `true` as the second argument means "return
  `NULL` if unset, don't error" - and `company_id = NULL` is never true in SQL, so a
  connection that somehow runs without the value set is denied everything, not granted
  everything. Fail closed by construction.

**A table with no RLS policy is not protected by this feature at all.** `db_query` runs the
same way against every table on a connection; whether a given table is actually isolated
depends entirely on whether *that table* has a working policy. This is deliberate, not a gap
to work around in Pepe: trying to enforce tenant isolation by rewriting or validating
arbitrary agent-authored SQL in application code cannot be made reliable (a `WITH` clause, a
`JOIN`, an aggregate can all smuggle a read past a text-level check). Row-Level Security is
the one mechanism that actually holds regardless of how the query is written, because it
applies inside the database engine itself, not to the text of the query.

## Adding a connection

The dashboard's **Databases** page lists connections, shows whether each is tenant-scoped, and
has a form to add or remove one - the password field is never pre-filled or echoed back once
saved. Same thing from the CLI:

```bash
pepe db add clientes_prod --host db.internal --port 5432 --database billing \
  --user pepe_ro --password ${DB_CLIENTES_PROD_PASSWORD} \
  --tenant-column company_id --tenant-mode fixed --tenant-value acme-inc

pepe db list
pepe db remove clientes_prod
```

A connection with no `--tenant-column` (or an empty "Tenant column" field on the dashboard) is
unscoped - fine for a single-tenant database with nothing to isolate. One with a tenant column
needs a mode too:

- **`fixed`** - the value is a literal, e.g. one connection per client
  (`clientes_prod` above is always `acme-inc`, whoever asks).
- **`agent_field`** - the value is `"project"` or `"bare"`, resolved from the *calling agent's
  own* project or handle at query time - useful when one Pepe deployment serves several
  customers, each mapped to its own agent/project.

An agent can also manage connections from a conversation with the `manage_db` tool (same
add/list/remove actions), and query with `db_query` once it holds both tools. Both are risky
tools - not in the always-safe set, gated through the ordinary permission prompt like any
other tool that reaches outward.

## What the agent sees

A `db_query` result comes back wrapped in the same untrusted-content marker a `fetch_url`
result carries - it's data from outside the conversation, treated the same way. The tool
itself is Postgres-only; there is no equivalent for MySQL, SQLite or any other engine, since
Row-Level Security (and the fail-closed guarantee above) is specific to Postgres.
