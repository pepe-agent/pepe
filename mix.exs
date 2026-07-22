defmodule Pepe.MixProject do
  use Mix.Project

  def project do
    [
      app: :pepe,
      version: "0.10.1",
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
      dialyzer: [plt_add_apps: [:mix, :ex_unit], plt_local_path: "priv/plts", plt_core_path: "priv/plts"]
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
      {:phoenix, "~> 1.8.8"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      # Operational data that grows with usage (commitments, and more to come) - not
      # config.json, which stays a plain file for definitions. Ships its own SQLite via
      # rustler_precompiled, the same mechanism `mdex` below already uses.
      {:ecto_sqlite3, "~> 0.24"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons, github: "tailwindlabs/heroicons", tag: "v2.2.0", sparse: "optimized", app: false, compile: false, depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      # HTML parsing for `fetch_url`'s readable-text extraction (Pepe.Readable) - the
      # actual "readability" hex package pulls in httpoison/hackney (for a URL-fetching
      # convenience function this never calls) which conflicts with the idna version
      # already locked here, so this builds the extraction directly on Floki instead.
      {:floki, "~> 0.36"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:yaml_elixir, "~> 2.9"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:burrito, "~> 1.0"},
      {:owl, "~> 0.13"},
      # Scheduled tasks: cron-expression parsing + a pure-Elixir timezone database
      # (`tz` builds the zone data at compile time - no hackney/runtime download).
      {:crontab, "~> 1.1"},
      {:tz, "~> 0.28"},
      # Rate limiting (the widget's public, unauthenticated-by-design endpoint).
      {:hammer, "~> 7.0"},
      # Renders chat message markdown on the dashboard (tables, lists, headers, ...).
      {:mdex, "~> 0.7"},
      # The `browser` tool: drives a real Chrome over CDP directly (Mint.WebSocket) - no
      # ChromeDriver, no Node.js driver process, unlike every Playwright/Puppeteer binding.
      {:cdp_ex, "~> 0.9"},
      {:mimic, "~> 1.11", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:excoveralls, "~> 0.18", only: :test},
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
