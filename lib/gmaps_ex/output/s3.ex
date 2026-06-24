defmodule GmapsEx.Output.S3 do
  @moduledoc """
  Upload scrape results to S3. Equivalent to `s3uploader/` in the Go scraper.

  Configured via `:gmaps_ex, GmapsEx.Output.S3, bucket: ..., prefix: ...` in
  `config/runtime.exs`. If no bucket is configured, calls are no-ops.
  """

  alias GmapsEx.Place

  @spec upload_jsonl([Place.t()], String.t()) :: :ok | {:error, term()}
  def upload_jsonl(places, key_suffix) do
    case Application.get_env(:gmaps_ex, __MODULE__) do
      nil ->
        :ok

      cfg ->
        bucket = Keyword.fetch!(cfg, :bucket)
        prefix = Keyword.get(cfg, :prefix, "")
        key = Path.join(prefix, key_suffix)

        body =
          places
          |> Enum.map(&Jason.encode!(Place.to_attrs(&1)))
          |> Enum.join("\n")

        ExAws.S3.put_object(bucket, key, body)
        |> ExAws.request()
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
