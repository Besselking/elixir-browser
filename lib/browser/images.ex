defmodule Browser.Images do
  @moduledoc """
  Finding, fetching and sniffing the images a page uses.

  `index/2` runs on the parsed tree: every `<img>` that has a usable source gets an
  `"@src"` attribute holding the absolute URL, and the distinct URLs are returned so
  the session can fetch them. `fetch/2` produces image bytes that the window toolkit
  can decode (PNG, JPEG, GIF or BMP), converting other formats with macOS's `sips`.
  """

  alias Browser.Fetch

  @max_bytes 12 * 1024 * 1024

  # -- finding sources -----------------------------------------------------------

  @doc """
  Adds `"@src"` (absolute URL) to every `<img>` with a source and returns
  `{nodes, urls}` with the distinct URLs in document order.

  The source is `src`, else `data-src` (lazy loading), else the first candidate of
  `srcset`.
  """
  def index(nodes, base) do
    {nodes, urls} = Enum.map_reduce(nodes, [], &index_node(&1, base, &2))
    {nodes, urls |> Enum.reverse() |> Enum.uniq()}
  end

  defp index_node({:text, _} = t, _base, acc), do: {t, acc}

  defp index_node({:element, "img", attrs, kids}, base, acc) do
    attrs = absolutize_style(attrs, base)

    case source(attrs) do
      nil ->
        {{:element, "img", attrs, kids}, acc}

      src ->
        url = Fetch.resolve(base, src)
        {{:element, "img", attrs ++ [{"@src", url}], kids}, [url | acc]}
    end
  end

  defp index_node({:element, tag, attrs, kids}, base, acc) do
    {kids, acc} = Enum.map_reduce(kids, acc, &index_node(&1, base, &2))
    {{:element, tag, absolutize_style(attrs, base), kids}, acc}
  end

  # url() in a style attribute is relative to the page
  defp absolutize_style(attrs, base) do
    case List.keyfind(attrs, "style", 0) do
      {_, css} ->
        if String.contains?(css, "url("),
          do:
            List.keyreplace(
              attrs,
              "style",
              0,
              {"style", Browser.Backgrounds.absolutize(css, base)}
            ),
          else: attrs

      nil ->
        attrs
    end
  end

  @doc "The `url()` addresses in a computed `background-image` list."
  def background_urls(images), do: Browser.Backgrounds.urls(images)

  @doc "The image address an `<img>` with these attributes asks for, or nil."
  def source(attrs) do
    [attr(attrs, "src"), attr(attrs, "data-src"), first_candidate(attr(attrs, "srcset"))]
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != "" and not String.starts_with?(&1, "#")))
  end

  # "a.png 1x, b.png 2x" -> "a.png"; data URLs contain commas, so split on ", " only
  defp first_candidate(srcset) do
    srcset
    |> String.trim()
    |> String.split(~r/,\s+/, parts: 2)
    |> hd()
    |> String.split(~r/\s+/, parts: 2)
    |> hd()
  end

  defp attr(attrs, name), do: List.keyfind(attrs, name, 0, {nil, ""}) |> elem(1)

  # -- fetching ------------------------------------------------------------------

  @doc """
  Fetches the image at `url` (for a page at `base`): `{:ok, bytes, format}` with
  `format` one of `:png | :jpeg | :gif | :bmp`, or `{:error, reason}`.
  """
  def fetch(url, base) do
    with :ok <- check_allowed(url, base),
         {:ok, bytes} <- load(url),
         :ok <- check_size(bytes) do
      prepare(bytes)
    end
  end

  # Remote pages may not pull in local files, as for stylesheets.
  defp check_allowed(url, base) do
    scheme = URI.parse(url).scheme
    base_scheme = URI.parse(base).scheme
    allowed = if base_scheme == "file", do: ~w(file http https data), else: ~w(http https data)
    if scheme in allowed, do: :ok, else: {:error, "blocked: #{scheme || "relative"} URL"}
  end

  defp load("data:" <> _ = url), do: decode_data_url(url)

  defp load(url) do
    case Fetch.load(url) do
      {:ok, body, _final} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_size(bytes) when byte_size(bytes) > @max_bytes, do: {:error, "image too large"}
  defp check_size(<<>>), do: {:error, "empty image"}
  defp check_size(_), do: :ok

  @doc "The bytes of a `data:` URL (base64 or percent-encoded)."
  def decode_data_url("data:" <> rest) do
    case String.split(rest, ",", parts: 2) do
      [meta, data] ->
        if String.ends_with?(String.downcase(meta), ";base64") do
          case Base.decode64(String.replace(URI.decode(data), ~r/\s/, ""), padding: false) do
            {:ok, bytes} -> {:ok, bytes}
            :error -> {:error, "bad base64"}
          end
        else
          {:ok, URI.decode(data)}
        end

      _ ->
        {:error, "bad data URL"}
    end
  end

  # -- formats -------------------------------------------------------------------

  @doc "The image format from the first bytes, or `:unknown`."
  def sniff(<<0x89, "PNG\r\n", 0x1A, 0x0A, _::binary>>), do: :png
  def sniff(<<0xFF, 0xD8, 0xFF, _::binary>>), do: :jpeg
  def sniff(<<"GIF8", v, "a", _::binary>>) when v in [?7, ?9], do: :gif
  def sniff(<<"BM", _::binary>>), do: :bmp
  def sniff(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: :webp

  def sniff(<<_::binary-size(4), "ftyp", brand::binary-size(4), _::binary>>) do
    if brand in ["avif", "avis"],
      do: :avif,
      else: if(brand in ["heic", "heix", "mif1"], do: :heic, else: :unknown)
  end

  def sniff(<<"II*", 0, _::binary>>), do: :tiff
  def sniff(<<"MM", 0, "*", _::binary>>), do: :tiff
  def sniff(_), do: :unknown

  # formats the toolkit reads directly; anything `sips` can read is converted to PNG
  defp prepare(bytes) do
    case sniff(bytes) do
      format when format in [:png, :jpeg, :gif, :bmp] -> {:ok, bytes, format}
      format when format in [:webp, :avif, :heic, :tiff] -> convert(bytes, format)
      :unknown -> {:error, "unknown image format"}
    end
  end

  @doc "Converts image bytes to PNG with macOS's `sips`: `{:ok, png, :png}` or `{:error, reason}`."
  def convert(bytes, format) do
    dir = Path.join(System.tmp_dir!(), "browser-img-#{System.unique_integer([:positive])}")
    input = Path.join(dir, "in.#{format}")
    output = Path.join(dir, "out.png")

    try do
      File.mkdir_p!(dir)
      File.write!(input, bytes)

      case System.cmd("sips", ["-s", "format", "png", input, "--out", output],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          case File.read(output) do
            {:ok, png} when png != "" -> {:ok, png, :png}
            _ -> {:error, "conversion produced nothing"}
          end

        {out, _} ->
          {:error, "cannot convert #{format}: #{String.slice(out, 0, 80)}"}
      end
    rescue
      e -> {:error, "cannot convert #{format}: #{Exception.message(e)}"}
    after
      File.rm_rf(dir)
    end
  end
end
