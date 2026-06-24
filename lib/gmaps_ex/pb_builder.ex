defmodule GmapsEx.PbBuilder do
  @moduledoc """
  Builds the `pb=` URL parameter that Google Maps' XHR search endpoint expects.

  This is a verbatim port of `buildGoogleMapsParams` in
  `google-maps-scraper-main/gmaps/searchjob.go:146-170`. The `pb=` template is the
  single most brittle string in the project — when Google changes the response shape,
  this is one of the places that may need adjustment.

  ## Format

  The `pb=` parameter is *not* binary protobuf — it's a URL-safe ASCII shape with
  `!<num><type><value>` segments. The Go scraper interpolates lon, lat, viewport
  width, viewport height, and zoom level into the template.
  """

  @default_viewport_w 600
  @default_viewport_h 800

  @typedoc "Required search parameters."
  @type params :: %{
          required(:query) => String.t(),
          required(:lat) => float(),
          required(:lon) => float(),
          required(:zoom) => float() | integer(),
          optional(:lang) => String.t(),
          optional(:viewport_w) => integer(),
          optional(:viewport_h) => integer()
        }

  @doc """
  Returns the query-string params Google expects. The caller appends them to
  `https://maps.google.com/search`.
  """
  @spec params(params()) :: [{String.t(), String.t()}]
  def params(%{} = p) do
    lang = Map.get(p, :lang, "en")
    viewport_w = Map.get(p, :viewport_w, @default_viewport_w)
    viewport_h = Map.get(p, :viewport_h, @default_viewport_h)
    zoom = p.zoom * 1.0

    pb =
      :io_lib.format(
        "!4m12!1m3!1d3826.902183192154!2d~.4f!3d~.4f!2m3!1f0!2f0!3f0!3m2!1i~B!2i~B!4f~.1f!7i20!8i0" <>
          "!10b1!12m22!1m3!18b1!30b1!34e1!2m3!5m1!6e2!20e3!4b0!10b1!12b1!13b1!16b1!17m1!3e1!20m3!5e2!6b1!14b1!46m1!1b0" <>
          "!96b1!19m4!2m3!1i360!2i120!4i8",
        [p.lon, p.lat, viewport_w, viewport_h, zoom]
      )
      |> IO.iodata_to_binary()

    [
      {"tbm", "map"},
      {"authuser", "0"},
      {"hl", lang},
      {"q", p.query},
      {"pb", pb}
    ]
  end
end
