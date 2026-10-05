defmodule Mix.Tasks.Browser.Layout do
  @shortdoc "Loads a page and prints its layout tree as text"

  @moduledoc """
  Loads a page (a URL or a file), lays it out and prints the boxes as an indented tree, so
  that a layout can be read, and two layouts compared, without looking at a picture.

      mix browser.layout URL_OR_FILE [--viewport 800x600] [--all] [--style]

  Each line is one element: its tag with `#id` and `.classes`, the border box that holds
  everything drawn for it and its descendants as `x,y WxH` in page coordinates, then its
  `display`/`position`/`float` when they are not the defaults. An element that drew nothing (an empty
  block) shows the row it sits in, with its height 0; one that is not in the layout at all shows
  `(no box)`. Text is printed as `"..."` with the box of the line it sits on, one line
  per run.

  Boxes are what was drawn: an element without a background or border, such as `<body>`,
  gets the bounds of its text and descendants rather than its own (invisible) border box.

  * `--viewport WxH` is the window the page is laid out in (default 800x600, which is what
    the reftests use for width).
  * `--style` adds the margin, border width and padding of each box, as `m=t,r,b,l`.
  * `--all` also lists elements that are not drawn (`<head>`, `<script>`, `display: none`).

  Needs no window, so it works in CI and cloud sessions, and on local files such as WPT
  reftests: run it on the test and on its reference and diff the output.
  """
  use Mix.Task

  alias Browser.{Layout, Nids, Page, Screenshot}

  @impl true
  def run(args) do
    {opts, rest} =
      OptionParser.parse!(args, strict: [viewport: :string, all: :boolean, style: :boolean])

    [input] = rest
    {width, height} = viewport(opts[:viewport] || "800x600")

    Application.put_env(:browser, :gui, false)
    Mix.Task.run("app.start")

    env = %{Browser.Style.default_env() | width: width, height: height}

    case Page.load(Browser.Fetch.normalize(input), env) do
      {:ok, page} -> Mix.shell().info(dump(page, width, height, opts))
      {:error, why} -> Mix.raise("Could not load #{input}: #{inspect(why)}")
    end
  end

  defp viewport(spec) do
    case Regex.run(~r/^(\d+)x(\d+)$/, spec) do
      [_, w, h] -> {String.to_integer(w), String.to_integer(h)}
      _ -> Mix.raise("--viewport wants WIDTHxHEIGHT, like 800x600")
    end
  end

  @doc false
  def dump(page, width, height, opts \\ []) do
    {items, content_height} =
      Layout.layout(page.nodes, width, &Screenshot.measure/2, height,
        svg_defs: page.svg_defs,
        margin: 0
      )

    tree = page.pruned || []
    parents = Nids.parents(tree)
    {markers, drawn} = Enum.split_with(items, &(&1.type == :box))
    # a `:box` marker spans the whole margin row, so it is only used for an element that drew
    # nothing else (an empty block), and then only for where it sits
    rects = Map.merge(Nids.rects(markers, parents), Nids.rects(drawn, parents))
    texts = items |> Enum.filter(&(&1.type == :text and is_integer(Map.get(&1, :nid))))
    texts = Enum.group_by(texts, & &1.nid)

    header = "viewport #{width}x#{height}, content height #{content_height}\n"
    header <> (tree |> Enum.flat_map(&lines(&1, 0, rects, texts, opts)) |> Enum.join("\n"))
  end

  defp lines({:text, _}, _depth, _rects, _texts, _opts), do: []

  defp lines({:element, tag, attrs, kids}, depth, rects, texts, opts) do
    nid = attr(attrs, "@nid")
    rect = rects[nid]
    computed = attr(attrs, "@computed") || %{}
    hidden? = rect == nil or computed["display"] == "none"

    if hidden? and not Keyword.get(opts, :all, false) do
      []
    else
      pad = String.duplicate("  ", depth)

      own =
        pad <> label(tag, attrs) <> " " <> box(rect) <> flags(computed) <> style(computed, opts)

      runs =
        for t <- Map.get(texts, nid, []),
            do: "#{pad}  #{inspect(t.text)} #{box({t.x, t.y, t.w, t.h})}"

      [own | runs ++ Enum.flat_map(kids, &lines(&1, depth + 1, rects, texts, opts))]
    end
  end

  defp label(tag, attrs) do
    id = if i = attr(attrs, "id"), do: "#" <> i, else: ""

    classes =
      case attr(attrs, "class") do
        c when is_binary(c) -> c |> String.split() |> Enum.map_join(&("." <> &1))
        _ -> ""
      end

    "<#{tag}>#{id}#{classes}"
  end

  defp box(nil), do: "(no box)"
  defp box({x, y, w, h}), do: "#{n(x)},#{n(y)} #{n(w)}x#{n(h)}"

  defp n(v) when is_float(v),
    do: v |> Float.round(2) |> to_string() |> String.replace(~r/\.0$/, "")

  defp n(v), do: to_string(v)

  @defaults %{
    "display" => ["block", "inline", "none"],
    "position" => ["static"],
    "float" => ["none"]
  }

  defp flags(computed) do
    for {prop, plain} <- @defaults,
        v = computed[prop],
        v not in plain,
        into: "",
        do: " #{prop}=#{v}"
  end

  defp style(computed, opts) do
    if Keyword.get(opts, :style, false) do
      for {label, prefix, suffix} <- [
            {"m", "margin-", ""},
            {"b", "border-", "-width"},
            {"p", "padding-", ""}
          ],
          into: "" do
        sides = for s <- ~w(top right bottom left), do: n(num(computed[prefix <> s <> suffix]))
        if Enum.all?(sides, &(&1 == "0")), do: "", else: " #{label}=" <> Enum.join(sides, ",")
      end
    else
      ""
    end
  end

  defp num(v) when is_number(v), do: v
  defp num(_), do: 0

  defp attr(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      {_, v} -> v
      nil -> nil
    end
  end
end
