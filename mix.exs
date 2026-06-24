defmodule GmapsEx.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nagieeb/gmaps_ex"

  def project do
    [
      app: :gmaps_ex,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),

      # hex.pm
      name: "GmapsEx",
      description: description(),
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),

      # dialyzer
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_file: {:no_warn, "_build/plts/dialyzer.plt"}
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {GmapsEx.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp description do
    "Pure-Elixir Google Maps scraper. No browser. ~30 fields per place via direct XHR. " <>
      "Oban + Broadway + Ecto + PubSub. Embeds as a library in your Phoenix/Elixir app."
  end

  defp package do
    [
      maintainers: ["Mohammed Nagieeb"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "Docs" => "https://hexdocs.pm/gmaps_ex"
      },
      files: ~w(lib priv/repo/migrations .formatter.exs mix.exs README.md LICENSE CHANGELOG.md
           USAGE.md PRODUCTION.md EMBEDDING.md COMPARISON.md GAPS.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "USAGE.md": [title: "Usage guide"],
        "EMBEDDING.md": [title: "Embedding in your app"],
        "PRODUCTION.md": [title: "Production & scale"],
        "COMPARISON.md": [title: "vs. Go scraper"],
        "GAPS.md": [title: "Known limitations"],
        "CHANGELOG.md": [title: "Changelog"]
      ],
      groups_for_modules: [
        "Public API": [
          GmapsEx,
          GmapsEx.Place,
          GmapsEx.Review,
          GmapsEx.Places,
          GmapsEx.Runner
        ],
        Parsers: [
          GmapsEx.Parser.Path,
          GmapsEx.Parser.Search,
          GmapsEx.Parser.Place,
          GmapsEx.Parser.Hours,
          GmapsEx.Parser.Reviews,
          GmapsEx.Parser.HtmlExtractor,
          GmapsEx.PbBuilder
        ],
        Reviews: [
          GmapsEx.Reviews,
          GmapsEx.Reviews.Backend,
          GmapsEx.Reviews.Backend.Http,
          GmapsEx.Reviews.PbBuilder,
          GmapsEx.Reviews.RpcParser,
          GmapsEx.ReviewsPersistence
        ],
        Workers: [
          GmapsEx.Workers.SearchWorker,
          GmapsEx.Workers.PlaceWorker,
          GmapsEx.Workers.ReviewsWorker,
          GmapsEx.Workers.EmailWorker
        ],
        HTTP: [
          GmapsEx.Http.Client,
          GmapsEx.Http.ProxyPool,
          GmapsEx.Http.SessionStore,
          GmapsEx.Http.RateLimiter
        ],
        Output: [
          GmapsEx.Output.Csv,
          GmapsEx.Output.Jsonl,
          GmapsEx.Output.S3
        ],
        Infrastructure: [
          GmapsEx.Repo,
          GmapsEx.Application,
          GmapsEx.Dedupe,
          GmapsEx.Exiter,
          GmapsEx.Telemetry
        ]
      ]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:floki, "~> 0.36"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:oban, "~> 2.18"},
      {:broadway, "~> 1.1"},
      {:hammer, "~> 7.0"},
      {:nimble_csv, "~> 1.2"},
      {:nimble_options, "~> 1.1"},
      {:phoenix_pubsub, "~> 2.1"},
      {:telemetry, "~> 1.3"},
      {:telemetry_metrics, "~> 1.0"},

      # Optional S3 output sink — only loaded if user opts in
      {:ex_aws, "~> 2.5", optional: true},
      {:ex_aws_s3, "~> 2.5", optional: true},
      {:sweet_xml, "~> 0.7", optional: true},

      # Browser-based review fallbacks intentionally NOT declared here —
      # `playwright` pulls cowlib via gun which doesn't compile on OTP 28+,
      # and `lightpanda_ex` is v0.1.0 (too new). Users wanting full-reviews
      # pagination add these to their own app's mix.exs:
      #   {:lightpanda_ex, "~> 0.1"}    # opt-in
      #   {:playwright, "~> 1.49"}      # opt-in
      # GmapsEx.Reviews.Backend.{Lightpanda,Playwright,Chain} use
      # Code.ensure_loaded?/1 to gracefully no-op until the user adds them.

      # Dev / test only
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.1", only: :test},
      {:plug, "~> 1.15", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      precommit: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "test"
      ]
    ]
  end
end
