# Pepe.RepoSetup runs Ecto.Migrator.run/4 fresh per test (each test's own PEPE_HOME means
# its own SQLite file, migrated on demand) - the migration file itself gets recompiled every
# time, which is otherwise a harmless "redefining module" warning on every single test.
Code.compiler_options(ignore_module_conflict: true)

ExUnit.start()

# Modules we stub in tests via Mimic (e.g. the WhatsApp delivery over the Graph API,
# so a webhook round-trip test can capture the outbound message without the network).
Mimic.copy(Pepe.Webhooks.WhatsApp)
Mimic.copy(Req)
Mimic.copy(Pepe.LLM)
