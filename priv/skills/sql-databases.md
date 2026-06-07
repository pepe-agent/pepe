# Query or update a SQL database - Postgres, MySQL, SQLite - from the shell, to answer a question from real data or make a change the user asked for.

Use this when the task needs the database itself: "how many leads came in last week", "mark
that order as shipped", "export the active users". You reach it with the database's own CLI
(`psql`, `mysql`, `sqlite3`) run through `bash`.

## Connecting without leaking the password

The connection details (host, user, database) are not secret - only the password is. `psql`
reads it from `PGPASSWORD`, `mysql` from `MYSQL_PWD` or a `--defaults-extra-file`, `sqlite3`
is just a file path. Take the password from the environment however the operator set it up: a
plain env var (allowed through `secrets.expose_env`) works, and a vault injected with `op run`
is the tidier habit (see the `vaults` skill).

```bash
# PGPASSWORD from the environment (a vault via op, or a plain exposed env var)
op run -- psql -h db.internal -U app -d prod -c "select count(*) from leads"
```

Do not paste the literal password into the command, where it lands in the trace - reference it
from the environment. If no password is set up at all, ask the operator to provide one; a plain
env var is a fine answer, a vault is a better one.

## Reading safely

- **Start with the shape.** `\dt` (psql) or `SHOW TABLES` lists tables; `\d table` describes
  one. Know the columns before you query them.
- **Always bound a read.** Put `LIMIT` on exploratory queries; a `select *` on a big table is
  a lot of rows and a lot of tokens. Aggregate (`count`, `sum`, `group by`) when the user
  wants a number, not a dump.
- **Use parameters, never string-built SQL.** If any value comes from the user or a message,
  pass it as a parameter (`psql -v`, a prepared statement), never glued into the query text -
  that is SQL injection, and a chat message is exactly the untrusted input that exploits it.

## Writing (stop and think first)

An `UPDATE`, `DELETE`, or `INSERT` changes real data and the permission gate will ask before
`bash` runs it. Before you say yes to yourself:

- **`SELECT` first.** Run the `WHERE` clause as a `SELECT` and look at exactly which rows it
  matches. A `DELETE` with a wrong `WHERE` (or none) is how tables get emptied.
- **Wrap risky changes in a transaction.** `BEGIN; ...; ` then check the row count, and only
  then `COMMIT` - or `ROLLBACK` if it touched more than you meant.
- **Confirm irreversible changes with the user**, in plain terms: "this will update 340 rows,
  go ahead?" Never run a destructive statement against production on your own initiative.
- **Prefer the replica for reads** if one exists, and never run a heavy query against a busy
  production primary without saying so.
