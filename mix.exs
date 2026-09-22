defmodule Pepe.MixProject do
  use Mix.Project

  def project do
    [
      app: :pepe,
      version: "0.19.1",
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
            # exgboost's Makefile shells out to XGBoost's own CMake build, which looks for
            # an OpenMP runtime for whichever target Burrito's NIF-recompile step is
            # building for (Burrito.Steps.Patch.RecompileNIFs, always invoked through zig
            # cc/c++ - confirmed empirically to run for every target here, linux_x86
            # included, not only the ones that differ from this runner's own OS/arch), and
            # there is none to find (CMake's `find_package(OpenMP)` fails outright,
            # aborting the whole NIF recompile before it produces anything). Every target
            # gets XGBoost's own `-DUSE_OPENMP=OFF` switch via nif_make_args (a `make`
            # command-line variable, which overrides the Makefile's own CMAKE_FLAGS),
            # trading multi-threaded GBM training for the build actually completing at all.
            #
            # The two Linux targets need a second switch. Burrito's Linux binaries bundle a
            # musl-linked BEAM (Burrito.Steps.Fetch.FetchMusl ships a musl 1.2.5 runtime
            # next to the ERTS), so the NIFs loaded into it have to be musl too - and they
            # are: zig resolves the bare `-target x86_64-linux` triplet Burrito hands it
            # (Burrito.Builder.Target.make_triplet/1) to `x86_64-unknown-linux-musl`, musl
            # being zig's default ABI when the triplet names no ABI at all. XGBoost's
            # src/common/io.cc then calls `mmap64` behind a plain `#if defined(__linux__)`,
            # and musl - which has had a 64-bit off_t since forever and so needs no separate
            # entry point - only spells that name under `_LARGEFILE64_SOURCE`, where its
            # sys/mman.h aliases it straight back to `mmap`. Without the define the NIF
            # recompile dies on `use of undeclared identifier 'mmap64'`. Defining it is an
            # alias-only change on musl, no ABI or off_t width shift, and it is the right
            # fix rather than forcing `-target x86_64-linux-gnu`: a glibc NIF would not load
            # into that musl BEAM in the first place.
            #
            # `-fcommon` is for a duplicate-symbol collision of exgboost's own making:
            # c/exgboost/include/utils.h declares `ErlNifResourceType *DMatrix_RESOURCE_TYPE;`
            # (and the Booster one) at file scope, so every .c that includes it emits a
            # tentative definition, and under the `-fno-common` that has been the default
            # since gcc 10 those collide at link time. Upstream papers over it with
            # `-Wl,--allow-multiple-definition`, which zig's linker refuses outright rather
            # than ignoring - see strip_exgboost_link_workaround/1 below, which takes that
            # flag back out. `-fcommon` merges the tentative definitions the way the code
            # assumes, which is what the linker flag was standing in for.
            #
            # `-Wno-error=int-conversion` is the last of it: exg_get_binary_from_address in
            # c/exgboost/src/utils.c memcpys straight from an ErlNifUInt64 address handed
            # over from Elixir, which is deliberate and correct on a 64-bit target but which
            # clang 16 and up reject by default rather than warn about. None of this ever
            # showed up on the macOS targets because Burrito only recompiles NIFs for a
            # cross build (Burrito.Builder.Target.is_cross_build?/1), and a macOS runner
            # building a macOS target is not one - it keeps the host-compiled NIFs. Linux is
            # hardcoded as always-cross there, so these two targets are the only ones that
            # put exgboost through zig at all.
            macos_arm: [os: :darwin, cpu: :aarch64, nif_make_args: ["CMAKE_FLAGS=-DUSE_OPENMP=OFF"]],
            macos_x86: [os: :darwin, cpu: :x86_64, nif_make_args: ["CMAKE_FLAGS=-DUSE_OPENMP=OFF"]],
            linux_arm: [
              os: :linux,
              cpu: :aarch64,
              nif_cflags: "-D_LARGEFILE64_SOURCE -fcommon -Wno-error=int-conversion",
              nif_cxxflags: "-D_LARGEFILE64_SOURCE",
              nif_make_args: ["CMAKE_FLAGS=-DUSE_OPENMP=OFF"]
            ],
            linux_x86: [
              os: :linux,
              cpu: :x86_64,
              nif_cflags: "-D_LARGEFILE64_SOURCE -fcommon -Wno-error=int-conversion",
              nif_cxxflags: "-D_LARGEFILE64_SOURCE",
              nif_make_args: ["CMAKE_FLAGS=-DUSE_OPENMP=OFF"]
            ],
            windows: [os: :windows, cpu: :x86_64, nif_make_args: ["CMAKE_FLAGS=-DUSE_OPENMP=OFF"]]
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
      else: [:assemble, &strip_exgboost_link_workaround/1]
  end

  # Runs Burrito with one line taken out of exgboost's Makefile, and put back afterwards.
  #
  # That Makefile appends `-Wl,--allow-multiple-definition` to LDFLAGS on anything that
  # isn't Darwin, to paper over the tentative definitions in its own utils.h (see the
  # `-fcommon` note up in releases/0, which fixes that properly). zig's linker rejects the
  # flag - "unsupported linker arg" - instead of ignoring it, and rejects `-z muldefs` the
  # same way, so the flag has to be gone before Burrito's NIF recompile runs.
  #
  # Editing the Makefile is what makes this exgboost-only. Burrito's knobs - nif_make_args,
  # nif_env, nif_cflags - are per *target*, not per dependency: overriding LDFLAGS through
  # them reaches every NIF recompiled for that target, and exqlite (which has LDFLAGS of its
  # own and no idea what libxgboost is) fails to link the moment it inherits exgboost's.
  #
  # The original is restored on the way out, including when the build fails, so a checkout
  # that has run `mix release` is not left quietly different from one that hasn't - it would
  # otherwise fail to build exgboost from source natively under any modern gcc or clang.
  defp strip_exgboost_link_workaround(release) do
    dep_path = Mix.Project.deps_paths()[:exgboost]
    makefile = dep_path && Path.join(dep_path, "Makefile")
    original = if makefile && File.regular?(makefile), do: File.read!(makefile)
    patched = original && Regex.replace(~r/^.*--allow-multiple-definition.*\R/m, original, "")

    if patched && patched != original, do: File.write!(makefile, patched)

    try do
      Burrito.wrap(release)
    after
      if patched && patched != original, do: File.write!(makefile, original)
    end
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
      # The WebSocket client for a persistent messaging connection (Discord's gateway,
      # Pepe.Gateways.Discord). Already in the lock as the transport of the browser tool's
      # CDP client (cdp_ex); declared here because it is used directly now, and a transitive
      # dependency is not something to lean on by name.
      {:mint_web_socket, "~> 1.0"},
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
      # The mid-size (EXGBoost) and large-scale (Axon + EXLA) tiers are not listed here -
      # they are conditional, see gbm_deps/0 and neural_deps/0 below.

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
    ] ++ gbm_deps() ++ neural_deps()
  end

  # Pepe.Insight's two upper tiers are conditional for one shared reason: each rests on a
  # native artifact that upstream publishes for Linux and macOS and not for native Windows
  # (no WSL), and neither gap is ours to close.
  #
  #   * EXLA fetches a precompiled XLA archive from Google. There is none for
  #     x86_64-windows-cpu, so compiling :exla there dies outright.
  #   * EXGBoost downloads a precompiled NIF; its releases cover apple-darwin, linux-gnu
  #     and riscv64 and stop there, so on Windows it falls back to building XGBoost from
  #     source, which its POSIX-shaped Makefile cannot do on that runner.
  #
  # Either build fails the *whole* Windows release, so `PEPE_SKIP_GBM=1` and
  # `PEPE_SKIP_NEURAL=1` drop them independently. That is how the Windows binary gets built
  # (see the `binaries` job in .github/workflows/ci.yml - both are set for that one target
  # and no other), and they stay separate knobs so that if EXGBoost ever ships a Windows
  # NIF, only one has to come back.
  #
  # What survives such a build is still real: `Pepe.Insight`'s four task types -
  # classification, regression, forecasting, clustering - all work, on Scholar's
  # logistic/linear regression and k-means. Only the two larger algorithm families are
  # absent, and `Pepe.Insight.Trainer` consults `GBMTrainer.available?/0`/
  # `Neural.available?/0` so a missing tier is never *selected* (it steps down to the next
  # one that is actually in the build) rather than failing at fit time.
  #
  # Anything other than "1" (including unset) keeps everything, so every other build -
  # source installs, Docker, the Linux/macOS binaries - is exactly what it has always been.
  defp gbm_deps do
    if System.get_env("PEPE_SKIP_GBM") == "1" do
      []
    else
      [
        # Gradient-boosted trees - the mid-size tabular tier, generally the strongest
        # baseline for business data at the row counts most operators actually have.
        # Pinned to 0.4.x deliberately: 0.5.x added an httpoison/ex_json_schema dependency
        # chain that collides with decimal ~> 3.0 (ecto_sqlite3) and the idna version this
        # project's HTTP stack already needs (the exact hackney/idna clash `fetch_url`'s
        # Floki-based extraction already avoids elsewhere in this file, for the same
        # reason) - 0.4.x has neither dependency.
        {:exgboost, "~> 0.4.0"}
      ]
    end
  end

  defp neural_deps do
    if System.get_env("PEPE_SKIP_NEURAL") == "1" do
      []
    else
      [
        # A small fixed-architecture neural net - the large-scale tier, reserved for an
        # operator with hundreds of millions of rows (patient events, ad records), where
        # that complexity actually pays for itself.
        {:axon, "~> 0.7"},
        # JIT-compiled Nx.Defn backend for the neural tier above - without it, Axon trains/
        # predicts on the plain interpreted Nx backend, unbounded in wall-clock time at real
        # data volumes. Scoped to just Pepe.Insight.Neural's own Axon calls
        # (`Neural.defn_options/0`, see its moduledoc) - never Nx's process-wide default
        # backend, so Scholar/EXGBoost are untouched. Ships a precompiled XLA binary for
        # Linux/macOS only: the neural tier runs uncompiled (correct, just unbounded-slow)
        # on a machine where that binary fails to load at runtime.
        {:exla, "~> 0.13"}
      ]
    end
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
