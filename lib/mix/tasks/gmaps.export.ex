defmodule Mix.Tasks.Gmaps.Export do
  @moduledoc """
  Export scraped places to CSV, JSONL, or S3.

  ## Examples

      mix gmaps.export --csv out.csv
      mix gmaps.export --jsonl out.jsonl
      mix gmaps.export --csv out.csv --jsonl out.jsonl --where "review_rating >= 4.5"
      mix gmaps.export --s3 --s3-key snapshots/2026-05-21.jsonl
  """

  use Mix.Task

  import Ecto.Query

  alias GmapsEx.{Place, Repo}
  alias GmapsEx.Output.{Csv, Jsonl, S3}

  @shortdoc "Export places to file or S3"

  @switches [
    csv: :string,
    jsonl: :string,
    s3: :boolean,
    s3_key: :string,
    where: :string,
    limit: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    Mix.Task.run("app.start")

    places =
      Place
      |> apply_where(opts[:where])
      |> apply_limit(opts[:limit])
      |> Repo.all()

    Mix.shell().info("Loaded #{length(places)} places from DB")

    if path = opts[:csv] do
      Csv.write(places, path)
      Mix.shell().info("CSV → #{path}")
    end

    if path = opts[:jsonl] do
      Jsonl.write(places, path)
      Mix.shell().info("JSONL → #{path}")
    end

    if opts[:s3] do
      key = opts[:s3_key] || "places-#{DateTime.utc_now() |> DateTime.to_iso8601()}.jsonl"

      case S3.upload_jsonl(places, key) do
        :ok -> Mix.shell().info("S3 → #{key}")
        {:error, reason} -> Mix.shell().error("S3 upload failed: #{inspect(reason)}")
      end
    end

    if opts == [] do
      Mix.shell().error("No output format specified. Use --csv, --jsonl, or --s3.")
    end
  end

  defp apply_where(query, nil), do: query
  defp apply_where(query, sql_fragment), do: from(p in query, where: fragment(^sql_fragment))

  defp apply_limit(query, nil), do: query
  defp apply_limit(query, n), do: from(p in query, limit: ^n)
end
