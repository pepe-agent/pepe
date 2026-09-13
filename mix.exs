defmodule Pepe.MixProject do
  use Mix.Project

  def project do
    [
      app: :pepe,
      version: "0.18.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      escript: escript(),
      releases: releases(),
      listeners: [Phoenix.CodeReloader],
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        ignore_warnings: ".dialyzer_ignore.exs"
      ]
    ]
  end

  # Standalone `pepe` executable, built with `mix escript.build`.
  # Requires Erlang/Elixir on the target machine (used for dev / hackers).
  defp escript do
    [main_module: Pepe.CLI, name: "pepe"]
  end

  # Self-contained, runtime-bundled binaries built with Burrito (Zig under the
  # hood). These need nothing installed on the target machine and back the
  # `curl ... | bash` one-liner installer. Build with:
  #
  #     MIX_ENV=prod mix release                       # all targets
  #     BURRITO_TARGET=macos_arm MIX_ENV=prod mix release   # a single target
  defp releases do
    [
      pepe: [
        steps: release_steps(),
        burrito: [
          targets: [
            macos_arm: [os: :darwin, cpu: :aarch64],
            macos_x86: [os: :darwin, cpu: :x86_64],
            linux_arm: [os: :linux, cpu: :aarch64],
            linux_x86: [os: :linux, cpu: :x86_64],
            windows: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  # Burrito exists to cross-compile a *portable* binary for someone else's machine.
  # Inside a container there is nothing to be portable about - the image is the
  # target - so the Docker build sets PEPE_PLAIN_RELEASE and gets a plain OTP
  # release instead: same `bin/pepe`, no bundled ERTS-per-OS, a far smaller image.
  defp release_steps do
    if System.get_env("PEPE_PLAIN_RELEASE"),
      do: [:assemble],
      else: [:assemble, &Burrito.wrap/1]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Pepe.Application, []},
      extra_applications: [:logger, :runtime_tools, :mnesia]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        predeploy: :test,
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        dialyzer: :dev,
        credo: :dev
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      ## Web
      ## What is it: the HTTP/WebSocket surface - the OpenAI-compatible API, the
      ## dashboard, and the asset pipeline that builds them.
      {:phoenix, "~> 1.8.8"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:bandit, "~> 1.5"},
      {:dns_cluster, "~> 0.2.0"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons, github: "tailwindlabs/heroicons", tag: "v2.2.0", sparse: "optimized", app: false, compile: false, depth: 1},

      ## Data & persistence
      ## What is it: Pepe's own operational store (Pepe.Repo, SQLite) and the driver
      ## behind db_query's connections to an operator's own external Postgres database.
      {:ecto_sql, "~> 3.13"},
      # Operational data that grows with usage (commitments, and more to come) - not
      # config.json, which stays a plain file for definitions. Ships its own SQLite via
      # rustler_precompiled, the same mechanism `mdex` below already uses.
      {:ecto_sqlite3, "~> 0.24"},
      # The `db_query` tool's connections to an operator-configured external Postgres
      # database (customer data, not Pepe's own store) - a standalone driver, not a full
      # Ecto.Repo, since these are dynamic, runtime-configured, possibly-many connections
      # rather than one static schema known at compile time.
      {:postgrex, "~> 0.19"},

      ## HTTP & content
      ## What is it: talking to the outside world (model providers, fetch_url, email)
      ## and turning what comes back into something an agent or the dashboard can use.
      {:req, "~> 0.5"},
      {:swoosh, "~> 1.16"},
      # HTML parsing for `fetch_url`'s readable-text extraction (Pepe.Readable) - the
      # actual "readability" hex package pulls in httpoison/hackney (for a URL-fetching
      # convenience function this never calls) which conflicts with the idna version
      # already locked here, so this builds the extraction directly on Floki instead.
      {:floki, "~> 0.36"},
      # Renders chat message markdown on the dashboard (tables, lists, headers, ...).
      {:mdex, "~> 0.7"},

      ## Observability
      ## What is it: telemetry plumbing for the dashboard's own live metrics.
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},

      ## Core plumbing
      ## What is it: general-purpose libraries most of the app reaches for directly -
      ## JSON, i18n, YAML config.
      {:jason, "~> 1.2"},
      {:gettext, "~> 1.0"},
      {:yaml_elixir, "~> 2.9"},

      ## Scheduling
      ## What is it: cron-expression parsing and a pure-Elixir timezone database for
      ## Scheduled tasks and Watches.
      # Scheduled tasks: cron-expression parsing + a pure-Elixir timezone database
      # (`tz` builds the zone data at compile time - no hackney/runtime download).
      {:crontab, "~> 1.1"},
      {:tz, "~> 0.28"},

      ## Security
      ## What is it: rate limiting and password hashing for the parts of Pepe exposed
      ## before a human is already authenticated.
      # Rate limiting (the widget's public, unauthenticated-by-design endpoint).
      {:hammer, "~> 7.0"},
      # Hashes a literal dashboard password before it's written to config.json.
      # A `${ENV_VAR}` reference never touches this (the real secret stays out of the
      # file entirely, same as every other credential), but a literal password typed
      # via `pepe dashboard password '...'` used to be stored as plain text, readable
      # from the live file or any backup/.bak of it.
      {:bcrypt_elixir, "~> 3.0"},

      ## Tool sandboxes
      ## What is it: the runtimes behind specific builtin tools that need more than a
      ## plain Elixir function - a scripting language, a browser protocol.
      # The `run_code` tool: a pure-BEAM Lua 5.3 interpreter (no NIF, no external
      # binary), so a runaway script is killed by an ordinary Task timeout and the
      # sandbox only ever sees what we explicitly bind into it.
      {:luerl, "~> 1.5"},
      # The `browser` tool: drives a real Chrome over CDP directly (Mint.WebSocket) - no
      # ChromeDriver, no Node.js driver process, unlike every Playwright/Puppeteer binding.
      {:cdp_ex, "~> 0.9"},

      ## Machine learning (Pepe.Insight)
      ## What is it: the three algorithm families Pepe.Insight.Trainer picks between
      ## automatically by data volume - small (Scholar), mid-size tabular (EXGBoost),
      ## large-scale (Axon, JIT-compiled via EXLA where available). All build on `:nx`,
      ## pulled in transitively.
      # Classical ML (logistic/linear regression) - the small-data tier: fast, robust, no
      # overfitting risk, a model that just works instantly for a few hundred to a couple
      # thousand rows.
      {:scholar, "~> 0.3"},
      # Gradient-boosted trees - the mid-size tabular tier, generally the strongest
      # baseline for business data at the row counts most operators actually have.
      # Pinned to 0.4.x deliberately: 0.5.x added an httpoison/ex_json_schema dependency
      # chain that collides with decimal ~> 3.0 (ecto_sqlite3) and the idna version this
      # project's HTTP stack already needs (the exact hackney/idna clash `fetch_url`'s
      # Floki-based extraction already avoids elsewhere in this file, for the same
      # reason) - 0.4.x has neither dependency.
      {:exgboost, "~> 0.4.0"},
      # A small fixed-architecture neural net - the large-scale tier, reserved for an
      # operator with hundreds of millions of rows (patient events, ad records), where
      # that complexity actually pays for itself.
      {:axon, "~> 0.7"},
      # JIT-compiled Nx.Defn backend for the neural tier above - without it, Axon trains/
      # predicts on the plain interpreted Nx backend, unbounded in wall-clock time at real
      # data volumes. Scoped to just Pepe.Insight.Neural's own Axon calls
      # (`Neural.defn_options/0`, see its moduledoc) - never Nx's process-wide default
      # backend, so Scholar/EXGBoost above are untouched. A required dependency that only
      # ships a precompiled XLA binary for Linux/macOS: it compiles, but the neural tier
      # only ever runs uncompiled (correct, just unbounded-slow) on a machine where the
      # binary fails to load at runtime - a native Windows build (no WSL) fails to compile
      # at all, since there is no binary for it to even attempt to fetch. Gate this
      # dependency out of a native Windows build's mix.exs if that target ever needs one.
      {:exla, "~> 0.13"},

      ## Packaging & ops
      ## What is it: how Pepe becomes a runnable thing - the standalone binary and the
      ## CLI's own terminal output.
      {:burrito, "~> 1.0"},
      {:owl, "~> 0.13"},

      ## Test only
      ## What is it: never shipped, only loaded for `mix test`.
      {:mimic, "~> 1.11", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:excoveralls, "~> 0.18", only: :test},

      ## Dev/test static analysis
      ## What is it: `mix predeploy`'s two gates (type checking, linting) - never in a
      ## production release.
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.1", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind pepe", "esbuild pepe"],
      "assets.deploy": [
        "tailwind pepe --minify",
        "esbuild pepe --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      # Run before pushing: everything precommit does, plus the two static-analysis
      # gates that are cheap to skip locally but too easy to let rot - both must
      # exit clean (no findings/warnings), not just run.
      predeploy: ["precommit", "credo", "dialyzer"]
    ]
  end
end
