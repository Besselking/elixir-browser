defmodule Browser.UI do
  @moduledoc "wx widgets: window construction, painting, font metrics and hit testing."

  require Record
  Record.defrecord(:wx, Record.extract(:wx, from_lib: "wx/include/wx.hrl"))
  Record.defrecord(:wxMouse, Record.extract(:wxMouse, from_lib: "wx/include/wx.hrl"))
  Record.defrecord(:wxCommand, Record.extract(:wxCommand, from_lib: "wx/include/wx.hrl"))
  Record.defrecord(:wxSize, Record.extract(:wxSize, from_lib: "wx/include/wx.hrl"))
  Record.defrecord(:wxKey, Record.extract(:wxKey, from_lib: "wx/include/wx.hrl"))

  @view :browser_view
  @images :browser_images
  @wx_default 70
  @wx_teletype 76
  @wx_normal 90
  @wx_italic 93
  @expand 8192
  @all 240
  @te_process_enter 1024
  @horizontal 4
  @vertical 8

  defstruct [
    :frame,
    :url,
    :back,
    :forward,
    :reload,
    :panel,
    :status,
    :cursors,
    :toolbar,
    :suggest,
    :tabs
  ]

  def build do
    :ets.new(@view, [:named_table, :public])
    :ets.new(@images, [:named_table, :public])
    :ets.insert(@view, {:view, [], 0, true})
    set_page([])
    :ets.insert(@view, {:sx, 0})

    Browser.TabStrip.init()
    wx = :wx.new()
    frame = :wxFrame.new(wx, -1, ~c"Elixir Browser", size: {960, 720})

    tabs = :wxPanel.new(frame, size: {-1, Browser.TabStrip.height()}, style: 65536)
    toolbar = :wxPanel.new(frame)
    back = :wxButton.new(toolbar, -1, label: ~c"◀", size: {40, -1})
    forward = :wxButton.new(toolbar, -1, label: ~c"▶", size: {40, -1})
    reload = :wxButton.new(toolbar, -1, label: ~c"⟳", size: {40, -1})
    url = :wxTextCtrl.new(toolbar, -1, style: @te_process_enter)

    row = :wxBoxSizer.new(@horizontal)
    for b <- [back, forward, reload], do: :wxSizer.add(row, b, border: 3, flag: @all)
    :wxSizer.add(row, url, proportion: 1, border: 3, flag: @all)
    :wxWindow.setSizer(toolbar, row)

    # FULL_REPAINT_ON_RESIZE | WANTS_CHARS (Tab, Enter and arrows arrive as char events)
    panel = :wxPanel.new(frame, style: 65536 + 262_144)
    :wxWindow.setBackgroundColour(panel, {255, 255, 255})
    :wxWindow.setBackgroundStyle(panel, :wxe_util.get_const(:wxBG_STYLE_PAINT))

    # a CSS pixel is a point only at macOS's 72 dpi; at 96 dpi a font drawn in points would be
    # 4/3 taller than the lines laid out for it
    dc = :wxClientDC.new(panel)
    {_, ppi} = :wxDC.getPPI(dc)
    :wxClientDC.destroy(dc)
    # a Retina display reports its device pixels (144 for 2x), while fonts are sized in
    # logical ones: the density that matters is per logical pixel
    scale = max(:wxWindow.getContentScaleFactor(panel), 1)
    :persistent_term.put({__MODULE__, :ppi}, max(ppi / scale, 1))

    status = :wxStatusBar.new(frame)
    :wxFrame.setStatusBar(frame, status)

    col = :wxBoxSizer.new(@vertical)
    :wxSizer.add(col, tabs, flag: @expand)
    :wxSizer.add(col, toolbar, flag: @expand)
    :wxSizer.add(col, panel, proportion: 1, flag: @expand)
    :wxWindow.setSizer(frame, col)

    # wxID_EXIT is moved into the macOS application menu as "Quit", with Cmd+Q
    file = :wxMenu.new()
    :wxMenu.append(file, 5100, ~c"New Tab\tCtrl+T")
    :wxMenu.append(file, 5101, ~c"Close Tab\tCtrl+W")
    :wxMenu.append(file, 5102, ~c"Reopen Closed Tab\tCtrl+Shift+T")
    :wxMenu.appendSeparator(file)
    :wxMenu.append(file, 5006, ~c"Quit\tCtrl+Q")
    menubar = :wxMenuBar.new()
    :wxMenuBar.append(menubar, file, ~c"File")

    edit = :wxMenu.new()
    :wxMenu.append(edit, 5031, ~c"Cut\tCtrl+X")
    :wxMenu.append(edit, 5032, ~c"Copy\tCtrl+C")
    :wxMenu.append(edit, 5035, ~c"Select All\tCtrl+A")
    :wxMenuBar.append(menubar, edit, ~c"Edit")
    :wxFrame.setMenuBar(frame, menubar)

    :wxFrame.connect(frame, :close_window)
    :wxFrame.connect(frame, :command_menu_selected)
    :wxTextCtrl.connect(url, :command_text_enter)
    :wxTextCtrl.connect(url, :command_text_updated)

    # up, down and escape belong to the suggestions; everything else is typing
    me_url = self()

    :wxTextCtrl.connect(url, :key_down,
      callback: fn wx(event: wxKey(keyCode: k)), ev ->
        if k in [27, 315, 317], do: send(me_url, {:url_key, k}), else: :wxEvent.skip(ev)
      end
    )

    # the dropdown floats over the page, below the address bar
    suggest = :wxListBox.new(frame, -1, pos: {0, 0}, size: {100, 100})
    :wxWindow.hide(suggest)
    :wxListBox.connect(suggest, :command_listbox_selected)
    for b <- [back, forward, reload], do: :wxButton.connect(b, :command_button_clicked)
    :wxPanel.connect(tabs, :left_down)
    :wxPanel.connect(tabs, :middle_down)
    :wxPanel.connect(tabs, :paint, callback: fn _ev, _obj -> Browser.TabStrip.paint(tabs) end)
    :wxPanel.connect(panel, :left_down)
    :wxPanel.connect(panel, :middle_down)
    :wxPanel.connect(panel, :right_down)
    :wxPanel.connect(panel, :left_up)
    :wxPanel.connect(panel, :left_dclick)
    :wxPanel.connect(panel, :motion)
    # the event record does not say which way the wheel turned (a sideways swipe of a
    # trackpad is not a vertical scroll), so the callback tells the session
    me = self()

    :wxPanel.connect(panel, :mousewheel,
      callback: fn wx(
                     event:
                       wxMouse(
                         wheelRotation: rot,
                         wheelDelta: delta,
                         linesPerAction: lines,
                         x: x,
                         y: y
                       )
                   ),
                   obj ->
        tag = if :wxMouseEvent.getWheelAxis(obj) == 0, do: :wheel, else: :hwheel
        send(me, {tag, rot, delta, lines, x, y})
      end
    )

    :wxPanel.connect(panel, :size)
    :wxPanel.connect(panel, :char)

    :wxPanel.connect(panel, :paint, callback: fn _ev, _obj -> paint(panel) end)

    :wxFrame.show(frame)
    :wxWindow.setFocus(panel)

    %__MODULE__{
      frame: frame,
      url: url,
      back: back,
      forward: forward,
      reload: reload,
      panel: panel,
      status: status,
      toolbar: toolbar,
      suggest: suggest,
      tabs: tabs,
      cursors: Map.new([arrow: 1, hand: 6, text: 7], fn {k, id} -> {k, :wxCursor.new(id)} end)
    }
  end

  @doc "Whether the system theme is dark (the toolbar's face colour is)."
  def dark? do
    colour = :wxSystemSettings.getColour(15)
    0.299 * elem(colour, 0) + 0.587 * elem(colour, 1) + 0.114 * elem(colour, 2) < 128
  end

  @doc "Scrolls the page sideways to `sx` pixels."
  def set_scroll_x(%{panel: panel}, sx) do
    :ets.insert(@view, {:sx, sx})
    :wxWindow.refresh(panel)
  end

  @band 256

  # The painter reads the page from `:persistent_term`, which hands out the same term to every
  # reader without copying it (an ETS lookup would copy every item, on every frame). It is
  # indexed by horizontal bands of the page so a frame only looks at what is near the window.
  defp set_page(items), do: :persistent_term.put({__MODULE__, :page}, index_page(items))

  @doc false
  def index_page(items) do
    {canvas, rest} =
      case items do
        [%{type: :canvas} = c | rest] -> {c, rest}
        _ -> {nil, items}
      end

    indexed = rest |> Enum.with_index() |> Enum.reverse()
    {sticky, normal} = Enum.split_with(indexed, fn {item, _} -> Map.has_key?(item, :stick) end)

    sticky =
      sticky |> Enum.reverse() |> Enum.map(&elem(&1, 0)) |> Enum.sort_by(&Map.get(&1, :z, 0))

    reach = fn {item, _} -> item.y + Map.get(item, :h, 40) + 40 end
    last = normal |> Enum.map(reach) |> Enum.max(fn -> 0 end) |> max(0) |> div(@band)

    bands =
      Enum.reduce(normal, %{}, fn {item, _} = entry, acc ->
        first = item.y |> max(0) |> div(@band) |> min(last)
        stop = reach.(entry) |> max(0) |> div(@band) |> min(last)

        Enum.reduce(first..stop//1, acc, fn b, acc ->
          Map.update(acc, b, [entry], &[entry | &1])
        end)
      end)

    bands = List.to_tuple(for b <- 0..last, do: Map.get(bands, b, []))
    %{canvas: canvas, sticky: sticky, bands: bands}
  end

  @doc """
  Hands the painter what to draw: the page's `items`, `overlay` items drawn over them (the
  selection), the scroll offset and the blink state of the text caret. The items are only
  indexed again when they are not the very list given last time.
  """
  def publish(items, overlay, scroll, caret_on \\ true) do
    unless Process.get(:published_items) === items do
      set_page(items)
      Process.put(:published_items, items)
    end

    :ets.insert(@view, {:view, overlay, scroll, caret_on})
  end

  @doc """
  Like `publish/4`, then asks wx to repaint. In `:diff` mode (same scroll offset) only the
  area covered by items that differ from the previous view, or by the caret when it
  blinks, is invalidated; anything else repaints the whole panel.
  """
  def update(%{panel: panel}, items, overlay, scroll, caret_on, mode \\ :full) do
    [{:view, old_overlay, old_scroll, old_caret}] = :ets.lookup(@view, :view)
    old_items = Process.get(:published_items, [])
    publish(items, overlay, scroll, caret_on)

    dirty =
      cond do
        mode == :diff and old_scroll == scroll and old_overlay == overlay ->
          if old_items === items,
            do:
              if(old_caret != caret_on, do: diff_items(old_items, items, true, nil), else: :none),
            else: diff_items(old_items, items, old_caret != caret_on, nil)

        true ->
          :full
      end

    case dirty do
      :none ->
        :ok

      :full ->
        :wxWindow.refresh(panel)

      {x, y, w, h} ->
        {cw, ch} = :wxWindow.getClientSize(panel)

        if w * h * 2 > cw * ch,
          do: :wxWindow.refresh(panel),
          else: :wxWindow.refreshRect(panel, {x - sx(), y - scroll, w, h})
    end
  end

  @doc """
  Repaints the pictures at `url` (a picture that has just been decoded) without touching
  the rest of the panel. `fixed?` items sit at screen positions, not page ones, so with
  any of those the whole panel is repainted.
  """
  def refresh_images(%{panel: panel}, items, url, scroll, fixed?) do
    pics = Enum.filter(items, &(&1.type == :image and &1.url == url))

    cond do
      pics == [] ->
        :ok

      Enum.any?(pics, fixed?) ->
        :wxWindow.refresh(panel)

      true ->
        {x, y, w, h} = pics |> Enum.map(&bbox/1) |> Enum.reduce(&union/2)
        :wxWindow.refreshRect(panel, {x - sx(), y - scroll, w, h})
    end
  end

  # bounding box (page coordinates) of what differs between two item lists, `:none` if
  # nothing, `:full` when the lists can't be compared item by item
  defp diff_items([same | old], [same | new], flip?, acc) do
    acc = if flip? and same.type == :caret, do: union(acc, bbox(same)), else: acc
    diff_items(old, new, flip?, acc)
  end

  defp diff_items([%{type: :canvas} | _], _, _, _), do: :full
  defp diff_items(_, [%{type: :canvas} | _], _, _), do: :full

  defp diff_items([a | old], [b | new], flip?, acc),
    do: diff_items(old, new, flip?, acc |> union(bbox(a)) |> union(bbox(b)))

  defp diff_items([], [], _, nil), do: :none
  defp diff_items([], [], _, acc), do: acc
  defp diff_items(_, _, _, _), do: :full

  defp union(nil, r), do: r

  defp union({x1, y1, w1, h1}, {x2, y2, w2, h2}) do
    x = min(x1, x2)
    y = min(y1, y2)
    {x, y, max(x1 + w1, x2 + w2) - x, max(y1 + h1, y2 + h2) - y}
  end

  # Everything an item can touch when drawn: shadows spread past their box, text runs a
  # line taller than its font size, the rest gets a little slack for antialiasing.
  defp bbox(%{type: :shadow, layers: [_ | _] = layers}) do
    layers
    |> Enum.map(fn %{rect: {x, y, w, h}} -> {x - 2, y - 2, w + 4, h + 4} end)
    |> Enum.reduce(&union/2)
  end

  defp bbox(%{type: :text, x: x, y: y, w: w, h: h}), do: {x - 6, y - 4, w + 12, h * 2 + 8}

  defp bbox(%{x: x, y: y, w: w} = item), do: {x - 4, y - 4, w + 8, Map.get(item, :h, 40) + 8}

  defp bbox(_), do: {0, 0, 1_000_000, 1_000_000}

  def client_width(%{panel: panel}), do: panel |> :wxWindow.getClientSize() |> elem(0)
  def client_height(%{panel: panel}), do: panel |> :wxWindow.getClientSize() |> elem(1)

  # -- fonts ---------------------------------------------------------------

  # the point size that is `px` pixels tall on this display
  defp points(px), do: max(round(px * 72 / :persistent_term.get({__MODULE__, :ppi}, 72)), 1)

  defp font(%{size: size, bold: bold, italic: italic, mono: mono} = style) do
    family = Map.get(style, :family)
    key = {:font, size, bold, italic, mono, family}

    case Process.get(key) do
      nil ->
        weight = :wxe_util.get_const(if bold, do: :wxFONTWEIGHT_BOLD, else: :wxFONTWEIGHT_NORMAL)
        {wx_family, face} = family_spec(family, mono)

        f =
          :wxFont.new(
            points(size),
            wx_family,
            if(italic, do: @wx_italic, else: @wx_normal),
            weight
          )

        if face, do: :wxFont.setFaceName(f, face)
        Process.put(key, f)
        f

      f ->
        f
    end
  end

  @wx_roman 72
  @wx_swiss 74
  @mono_generics ~w(monospace ui-monospace)
  @serif_generics ~w(serif ui-serif)
  @sans_generics ~w(sans-serif ui-sans-serif)
  @system_generics ~w(system-ui -apple-system blinkmacsystemfont ui-rounded cursive fantasy)

  # What a CSS font-family list means here: the first entry that is a generic family or a font
  # that is installed decides; `{wx family, face name or nil}`.
  defp family_spec(family, mono) do
    cache = {__MODULE__, :family, family, mono}

    case :persistent_term.get(cache, nil) do
      nil ->
        spec = resolve_family(family, mono)
        :persistent_term.put(cache, spec)
        spec

      spec ->
        spec
    end
  end

  defp resolve_family(family, mono) do
    names =
      for part <- String.split(family || "", ","),
          name = part |> String.trim() |> String.trim("\"") |> String.trim("'"),
          name != "",
          do: name

    found =
      Enum.find_value(names, fn name ->
        lower = String.downcase(name)

        cond do
          lower in @mono_generics -> {@wx_teletype, mono_face()}
          lower in @serif_generics -> {@wx_roman, nil}
          lower in @sans_generics -> {@wx_swiss, nil}
          lower in @system_generics -> {@wx_default, nil}
          installed?(name) -> {@wx_default, name}
          true -> nil
        end
      end)

    cond do
      found -> found
      mono -> {@wx_teletype, mono_face()}
      true -> {@wx_default, nil}
    end
  end

  # wx accepts any face name and quietly shows its default font for one that is not installed,
  # so a font exists when text in it is not as wide as in a face that cannot exist
  @probe "The quick brown fox jumps over the lazy dog 0123456789 WMiIl"

  defp installed?(name) do
    key = {__MODULE__, :installed, String.downcase(name)}

    case :persistent_term.get(key, nil) do
      nil ->
        result = probe_width(name) != probe_width("no such font \u2603")
        :persistent_term.put(key, result)
        result

      result ->
        result
    end
  end

  defp probe_width(face) do
    dc = :wxScreenDC.new()
    f = :wxFont.new(40, @wx_default, @wx_normal, :wxe_util.get_const(:wxFONTWEIGHT_NORMAL))
    :wxFont.setFaceName(f, String.to_charlist(face))
    :wxDC.setFont(dc, f)
    {w, _} = :wxDC.getTextExtent(dc, String.to_charlist(@probe))
    :wxScreenDC.destroy(dc)
    w
  end

  # wx's "teletype" family alone can mean Courier; the system's own fixed-width font is what
  # other programs on the platform show
  @wx_sys_ansi_fixed_font 11

  defp mono_face do
    case :persistent_term.get({__MODULE__, :mono_face}, nil) do
      nil ->
        sys = :wxSystemSettings.getFont(@wx_sys_ansi_fixed_font)
        face = if :wxFont.isOk(sys), do: sys |> :wxFont.getFaceName() |> to_string()
        face = if face in [nil, ""], do: nil, else: face
        :persistent_term.put({__MODULE__, :mono_face}, face || false)
        face

      false ->
        nil

      face ->
        face
    end
  end

  # widths cached per font; each uncached measurement is two synchronous wx calls
  # (~100us), and a relayout asks for the same text hundreds of times
  @measure_cache_limit 50_000

  @doc "A width cache that several measurers (each with its own DC) can share."
  def new_measure_cache, do: :ets.new(:measure_cache, [:set, :public])

  @doc """
  Returns a `(text, style) -> width` function (`(:content_height, style) -> px` gives the
  height of the font's glyphs) backed by a wx client DC. Widths are
  memoized in `cache`, so only text that changed costs a wx round trip. A measurer is used
  by one process at a time (its DC holds the current font); a second one on the same cache
  serves a background process.
  """
  def measurer(%{panel: panel}, cache \\ nil), do: dc_measurer(:wxClientDC.new(panel), cache)

  defp dc_measurer(dc, cache) do
    cache = cache || new_measure_cache()

    fn
      :content_height, %{size: size, bold: bold, italic: italic, mono: mono} = style ->
        key = {:content_height, size, bold, italic, mono, Map.get(style, :family)}

        case :ets.lookup(cache, key) do
          [{_, h}] ->
            h

          [] ->
            :wxDC.setFont(dc, font(style))
            {_w, h} = :wxDC.getTextExtent(dc, ~c"Hg")
            :ets.insert(cache, {key, h})
            h
        end

      text, %{size: size, bold: bold, italic: italic, mono: mono} = style ->
        key = {text, size, bold, italic, mono, Map.get(style, :family)}

        case :ets.lookup(cache, key) do
          [{_, w}] ->
            w

          [] ->
            :wxDC.setFont(dc, font(style))
            {w, _h} = :wxDC.getTextExtent(dc, String.to_charlist(text))
            if :ets.info(cache, :size) >= @measure_cache_limit, do: :ets.delete_all_objects(cache)
            :ets.insert(cache, {key, w})
            w
        end
    end
  end

  @doc """
  Returns a `(%{size, family, bold, italic}) -> {ex, ch}` function: the x-height and the
  advance of a "0" over the font size, measured from the font itself (the height of the ink
  of an "x" drawn on a bitmap) and memoized in `cache`.
  """
  def font_units(cache) do
    # the cascade runs in processes of its own (a page load, a restyle), which need wx's environment
    wx_env = :wx.get_env()

    fn %{size: size, family: family, bold: bold, italic: italic} = style ->
      key = {:units, size, family, bold, italic}

      case :ets.lookup(cache, key) do
        [{_, units}] ->
          units

        [] ->
          :wx.set_env(wx_env)
          units = measure_units(Map.put(style, :mono, Browser.Layout.mono_family?(family)))
          :ets.insert(cache, {key, units})
          units
      end
    end
  end

  # `font-size: 0` is real (icon fonts, hidden text); measure it as 1px so the ratios stay finite
  defp measure_units(%{size: size} = style) when size < 1, do: measure_units(%{style | size: 1})

  defp measure_units(%{size: size} = style) do
    side = max(ceil(size * 3), 8)
    bitmap = :wxBitmap.new(side, side)
    dc = :wxMemoryDC.new(bitmap)
    :wxDC.setBackground(dc, :wxBrush.new({255, 255, 255}))
    :wxDC.clear(dc)
    :wxDC.setFont(dc, font(style))
    :wxDC.setTextForeground(dc, {0, 0, 0})
    :wxDC.drawText(dc, ~c"x", {round(size), round(size)})
    {zero, _} = :wxDC.getTextExtent(dc, ~c"0")
    :wxMemoryDC.destroy(dc)
    image = :wxBitmap.convertToImage(bitmap)
    rows = ink_rows(:wxImage.getData(image), side)
    :wxImage.destroy(image)
    :wxBitmap.destroy(bitmap)
    {max(rows, 1) / size, max(zero, 1) / size}
  end

  # how many rows of an RGB image `side` pixels wide have anything but white in them
  defp ink_rows(rgb, side) do
    rgb
    |> :binary.bin_to_list()
    |> Enum.chunk_every(3 * side)
    |> Enum.count(fn row -> Enum.any?(row, &(&1 < 128)) end)
  end

  # -- pictures of a page without a window ------------------------------------------------

  @doc """
  Starts what drawing needs when there is no window (`snapshot/5`): wx, the tables the
  painter reads, and a measurer on a bitmap's DC. Returns the measurer.
  """
  def snapshot_start do
    :wx.new()

    for name <- [@view, @images], :ets.whereis(name) == :undefined do
      :ets.new(name, [:named_table, :public])
    end

    :ets.insert(@view, {:view, [], 0, true})
    :ets.insert(@view, {:sx, 0})
    dc_measurer(:wxMemoryDC.new(:wxBitmap.new(16, 16)), nil)
  end

  @doc """
  Paints `items` the way the window would, into a `width` x `height` bitmap, and saves it as
  PNG at `path`, with `overlay` items over them and the window `scroll` px down the page.
  Returns `true` when the file was written.
  """
  def snapshot(items, width, height, path, overlay \\ [], scroll \\ 0) do
    set_page(items)
    :ets.insert(@view, {:view, overlay, scroll, false})
    bitmap = :wxBitmap.new(width, height)
    dc = :wxMemoryDC.new(bitmap)
    paint_dc(dc)
    :wxMemoryDC.destroy(dc)
    :wxBitmap.saveFile(bitmap, String.to_charlist(path), :wxe_util.get_const(:wxBITMAP_TYPE_PNG))
  end

  # -- painting (runs in wx callback process) --------------------------------

  defp sx do
    case :ets.lookup(@view, :sx) do
      [{:sx, sx}] -> sx
      [] -> 0
    end
  end

  defp paint(panel) do
    dc = :wxPaintDC.new(panel)
    paint_dc(dc)
    :wxPaintDC.destroy(dc)
    :ok
  end

  defp paint_dc(dc) do
    [{:view, overlay, scroll, caret_on}] = :ets.lookup(@view, :view)

    %{canvas: canvas_item, sticky: sticky, bands: bands} =
      :persistent_term.get({__MODULE__, :page})

    Process.delete(:paint_font)
    Process.delete(:paint_color)
    # everything is drawn at page x: the origin moves with the horizontal scroll
    :wxDC.setDeviceOrigin(dc, -sx(), 0)

    canvas =
      case canvas_item do
        %{color: color} when color != nil -> color
        _ -> {255, 255, 255}
      end

    :wxDC.setBackground(dc, :wxBrush.new(canvas))
    :wxDC.clear(dc)
    draw_canvas_layers(dc, [canvas_item], scroll)
    # only the invalidated part of the window is drawn into, so items outside it are skipped
    {cx, cy, cw, ch} = :wxDC.getClippingBox(dc)

    # the items of the bands the window shows, in page order
    last = tuple_size(bands) - 1
    first_band = (cy + scroll) |> max(0) |> div(@band) |> min(last)
    last_band = (cy + ch + scroll) |> max(0) |> div(@band) |> min(last)

    near =
      first_band..last_band//1
      |> Enum.flat_map(&elem(bands, &1))
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.dedup_by(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    # sticky and fixed items are drawn last, over the page, shifted by how far the page has scrolled
    for item <- near ++ overlay ++ sticky,
        item.type != :canvas,
        item.type != :caret or caret_on,
        not Map.get(item, :hidden, false),
        sc = scroll - stick_shift(item, scroll),
        item.y - sc < cy + ch,
        item.y + Map.get(item, :h, 40) + 40 - sc > cy,
        item.x - 40 < cx + cw,
        item.x + Map.get(item, :w, 100_000) + 40 > cx do
      y = item.y - sc
      clip = Map.get(item, :clip)
      if clip, do: :wxDC.setClippingRegion(dc, {clip.x, clip.y - sc, clip.w, clip.h})

      # inside a transformed box everything is drawn through its matrices (see `new_gc/1`)
      xform = Map.get(item, :xform)
      if xform, do: Process.put(:xform, {xform, sc})
      draw_item(dc, item, y, sc)
      if xform, do: Process.delete(:xform)

      if clip, do: :wxDC.destroyClippingRegion(dc)
    end
  end

  # -- transformed boxes ------------------------------------------------------------------

  # A graphics context for `dc`, set up for the item being drawn: boxes with `transform` (or
  # `rotate`, `scale`) draw through their matrices, outermost first. A matrix works in page
  # coordinates; the window is `sc` px down the page, which is taken out here.
  defp new_gc(dc) do
    gc = :wxGraphicsContext.create(dc)

    case Process.get(:xform) do
      nil ->
        gc

      {matrices, sc} ->
        for {a, b, c, d, e, f} <- Enum.reverse(matrices) do
          matrix =
            :wxGraphicsContext.createMatrix(gc,
              a: a,
              b: b,
              c: c,
              d: d,
              tx: e + c * sc,
              ty: f + d * sc - sc
            )

          :wxGraphicsContext.concatTransform(gc, matrix)
        end

        gc
    end
  end

  # The plain DC cannot rotate or scale, so text, boxes and lines of transformed boxes are
  # drawn with the graphics context instead.
  defp draw_item(dc, %{type: type} = item, y, sc) do
    plain? = type in [:text, :hr, :caret] or (type == :rect and Map.get(item, :radius) == nil)

    if plain? and Process.get(:xform),
      do: draw_gc(dc, item, y),
      else: draw(dc, item, y, sc)
  end

  defp draw_gc(dc, %{type: :rect} = item, y) do
    gc = new_gc(dc)
    :wxGraphicsContext.setBrush(gc, :wxBrush.new(item.color))
    path = :wxGraphicsContext.createPath(gc)
    :wxGraphicsPath.addRectangle(path, item.x, y, item.w, item.h)
    :wxGraphicsContext.fillPath(gc, path)
    :wxGraphicsContext.destroy(gc)
  end

  defp draw_gc(dc, %{type: :text} = item, y) do
    gc = new_gc(dc)
    :wxGraphicsContext.setFont(gc, font(item), item.color)
    draw_gc_text(gc, item, y)

    if item.underline do
      uy = y + underline_offset(dc, item)
      gc_line(gc, item.color, item.x, uy, item.x + item.w, uy)
    end

    if item.strike do
      mid = y + strike_offset(dc, item)
      gc_line(gc, item.color, item.x, mid, item.x + item.w, mid)
    end

    :wxGraphicsContext.destroy(gc)
  end

  defp draw_gc(dc, %{type: :hr} = item, y) do
    gc = new_gc(dc)
    gc_line(gc, {170, 170, 170}, item.x, y, item.x + item.w, y)
    :wxGraphicsContext.destroy(gc)
  end

  defp draw_gc(dc, %{type: :caret} = item, y) do
    gc = new_gc(dc)
    gc_line(gc, item.color, item.x, y, item.x, y + item.h)
    :wxGraphicsContext.destroy(gc)
  end

  defp gc_line(gc, color, x0, y0, x1, y1) do
    :wxGraphicsContext.setPen(gc, :wxPen.new(color))
    path = :wxGraphicsContext.createPath(gc)
    :wxGraphicsPath.moveToPoint(path, x0, y0)
    :wxGraphicsPath.addLineToPoint(path, x1, y1)
    :wxGraphicsContext.strokePath(gc, path)
  end

  # -- shadows and background images --------------------------------------------------

  @no_radii {{0, 0}, {0, 0}, {0, 0}, {0, 0}}

  # an outer shadow: translucent shapes stacked from the biggest to the smallest, which
  # fades the edge like a blur
  # selected text: a translucent wash over it
  # text with `letter-spacing` or `word-spacing` goes down a character at a time, each after
  # the width of the ones before it and the spacing
  defp draw_gc_text(gc, item, y) do
    if spread?(item) do
      each_char(item, fn ch, prefix, extra ->
        {w, _, _, _} = :wxGraphicsContext.getTextExtent(gc, prefix)
        :wxGraphicsContext.drawText(gc, ch, item.x + w + extra, y)
      end)
    else
      :wxGraphicsContext.drawText(gc, String.to_charlist(item.text), item.x, y)
    end
  end

  defp draw_dc_text(dc, item, y) do
    if spread?(item) do
      each_char(item, fn ch, prefix, extra ->
        {w, _} = :wxDC.getTextExtent(dc, prefix)
        :wxDC.drawText(dc, ch, {round(item.x + w + extra), y})
      end)
    else
      :wxDC.drawText(dc, String.to_charlist(item.text), {item.x, y})
    end
  end

  defp spread?(item) do
    Map.get(item, :ls, 0) != 0 or
      (Map.get(item, :wsp, 0) != 0 and String.contains?(item.text, [" ", "\u00A0"]))
  end

  # calls `fun.(char, text_before_it, spacing_before_it)` for each character of the item
  defp each_char(item, fun) do
    ls = Map.get(item, :ls, 0)
    wsp = Map.get(item, :wsp, 0)
    chars = String.graphemes(item.text)

    chars
    |> Enum.with_index()
    |> Enum.reduce({[], 0}, fn {ch, i}, {before, spaces} ->
      prefix = before |> Enum.reverse() |> Enum.join() |> String.to_charlist()
      fun.(String.to_charlist(ch), prefix, i * ls + spaces * wsp)
      {[ch | before], spaces + if(ch in [" ", "\u00A0"], do: 1, else: 0)}
    end)
  end

  defp draw(dc, %{type: :selection} = item, y, _scroll) do
    gc = new_gc(dc)
    :wxGraphicsContext.setBrush(gc, :wxBrush.new({56, 132, 255, 90}))
    path = :wxGraphicsContext.createPath(gc)
    :wxGraphicsPath.addRectangle(path, item.x, y, item.w, item.h)
    :wxGraphicsContext.fillPath(gc, path)
    :wxGraphicsContext.destroy(gc)
  end

  # only marks where a control is
  defp draw(_dc, %{type: :box}, _y, _scroll), do: :ok

  defp draw(dc, %{type: :shadow} = item, _y, scroll) do
    gc = new_gc(dc)
    clip_to(gc, item, scroll)

    for %{rect: {x, y, w, h}, radii: radii, color: color} <- item.layers do
      :wxGraphicsContext.setBrush(gc, :wxBrush.new(color))
      path = :wxGraphicsContext.createPath(gc)
      outline(path, x, y - scroll, w, h, radii || @no_radii)
      :wxGraphicsContext.fillPath(gc, path)
    end

    :wxGraphicsContext.destroy(gc)
  end

  # an inset shadow: inside the box, frames (the box minus a hole) stacked from the
  # smallest hole to the biggest
  defp draw(dc, %{type: :inset_shadow} = item, y, scroll) do
    gc = new_gc(dc)
    clip_to(gc, item, scroll)
    :wxGraphicsContext.clip(gc, item.x, y, item.w, item.h)

    for %{hole: hole, color: color} <- item.layers do
      :wxGraphicsContext.setBrush(gc, :wxBrush.new(color))
      path = :wxGraphicsContext.createPath(gc)
      outline(path, item.x, y, item.w, item.h, item.radius || @no_radii)

      if hole do
        %{rect: {hx, hy, hw, hh}, radii: hradii} = hole
        outline(path, hx, hy - scroll, hw, hh, hradii || @no_radii)
      end

      # odd-even: what is inside the box but outside the hole
      :wxGraphicsContext.fillPath(gc, path, [{:fillStyle, 1}])
    end

    :wxGraphicsContext.destroy(gc)
  end

  defp draw(dc, %{type: :bgimage} = item, _y, scroll) do
    gc = new_gc(dc)
    clip_to(gc, item, scroll)
    Enum.each(item.layers, &draw_layer(gc, &1, item.radius, scroll))
    :wxGraphicsContext.destroy(gc)
  end

  # a decoded picture, scaled to its box
  defp draw(dc, %{type: :image} = item, y, scroll) do
    case :ets.lookup(@images, item.url) do
      [{_url, bitmap}] ->
        gc = new_gc(dc)

        if clip = Map.get(item, :clip),
          do: :wxGraphicsContext.clip(gc, clip.x, clip.y - scroll, clip.w, clip.h)

        :wxGraphicsContext.drawBitmap(gc, bitmap, item.x, y, item.w, item.h)
        :wxGraphicsContext.destroy(gc)

      [] ->
        :ok
    end
  end

  # a vector picture: its display list is relative to the item's top-left corner
  defp draw(dc, %{type: :svg} = item, y, scroll) do
    gc = new_gc(dc)
    clip_to(gc, item, scroll)
    :wxGraphicsContext.clip(gc, item.x, y, item.w, item.h)
    draw_svg(gc, item.ops, item.x, y)
    :wxGraphicsContext.destroy(gc)
  end

  # the focus ring: a 2px line around the control, following its rounded corners
  defp draw(dc, %{type: :ring} = item, y, _scroll) do
    gc = new_gc(dc)
    radii = item.radius || {{0, 0}, {0, 0}, {0, 0}, {0, 0}}
    c = item.color
    borders(gc, item.x, y, item.w, item.h, radii, %{w: {2, 2, 2, 2}, c: {c, c, c, c}})
    :wxGraphicsContext.destroy(gc)
  end

  defp draw(dc, %{type: :caret} = item, y, _scroll) do
    :wxDC.setPen(dc, :wxPen.new(item.color))
    :wxDC.drawLine(dc, {item.x, y}, {item.x, y + item.h})
  end

  # Boxes with rounded corners are drawn as paths on a graphics context: the
  # background fills a rounded outline, each border side is a straight strip and
  # each corner a ring segment in the colour of the thicker adjacent side.
  defp draw(dc, %{type: :rect, radius: radius} = item, y, scroll) when radius != nil do
    gc = new_gc(dc)

    if clip = Map.get(item, :clip),
      do: :wxGraphicsContext.clip(gc, clip.x, clip.y - scroll, clip.w, clip.h)

    if item.color do
      :wxGraphicsContext.setBrush(gc, :wxBrush.new(item.color))
      path = :wxGraphicsContext.createPath(gc)
      outline(path, item.x, y, item.w, item.h, radius)
      :wxGraphicsContext.fillPath(gc, path)
    end

    if item.border, do: borders(gc, item.x, y, item.w, item.h, radius, item.border)
    :wxGraphicsContext.destroy(gc)
  end

  # a translucent fill needs the graphics context
  defp draw(dc, %{type: :rect, color: color} = item, y, _scroll) when tuple_size(color) == 4 do
    gc = new_gc(dc)
    :wxGraphicsContext.setBrush(gc, :wxBrush.new(color))
    path = :wxGraphicsContext.createPath(gc)
    :wxGraphicsPath.addRectangle(path, item.x, y, item.w, item.h)
    :wxGraphicsContext.fillPath(gc, path)
    :wxGraphicsContext.destroy(gc)
  end

  defp draw(dc, %{type: :rect} = item, y, _scroll) do
    :wxDC.setPen(dc, cached({:pen, :none}, fn -> :wxPen.new({0, 0, 0}, style: 106) end))
    :wxDC.setBrush(dc, cached({:brush, item.color}, fn -> :wxBrush.new(item.color) end))
    :wxDC.drawRectangle(dc, {item.x, y}, {item.w, item.h})
  end

  defp draw(dc, %{type: :hr} = item, y, _scroll) do
    :wxDC.setPen(dc, pen({170, 170, 170}))
    :wxDC.drawLine(dc, {item.x, y}, {item.x + item.w, y})
  end

  # Every wx call is a round trip to the wx thread, so the font and colour are only set when
  # they differ from the previous word's (the paint starts with neither set).
  defp draw(dc, %{type: :text} = item, y, _scroll) do
    font_key = {item.size, item.bold, item.italic, item.mono, Map.get(item, :family)}

    if Process.get(:paint_font) != font_key do
      :wxDC.setFont(dc, font(item))
      Process.put(:paint_font, font_key)
    end

    if Process.get(:paint_color) != item.color do
      :wxDC.setTextForeground(dc, item.color)
      Process.put(:paint_color, item.color)
    end

    draw_dc_text(dc, item, y)

    if item.underline or item.strike do
      :wxDC.setPen(dc, pen(item.color))

      if item.underline do
        uy = y + underline_offset(dc, item)
        :wxDC.drawLine(dc, {item.x, uy}, {item.x + item.w, uy})
      end

      if item.strike do
        sy = y + strike_offset(dc, item)
        :wxDC.drawLine(dc, {item.x, sy}, {item.x + item.w, sy})
      end
    end
  end

  # Where the text's decorations go, measured from the top of the drawn glyph box: the baseline
  # sits `descent` above its bottom, so the underline is a little under that and the strike
  # line about a third of the font size above it. The glyph box is what the font really draws,
  # which is not the item's `h` (the font size) nor the line's height.
  defp underline_offset(dc, item) do
    {height, descent} = glyph_box(dc, item)
    height - descent + max(1, div(descent, 3))
  end

  defp strike_offset(dc, item) do
    {height, descent} = glyph_box(dc, item)
    height - descent - max(div(item.size * 3, 10), 2)
  end

  defp glyph_box(dc, item) do
    key = {:glyph_box, item.size, item.bold, item.italic, item.mono, Map.get(item, :family)}

    case Process.get(key) do
      nil ->
        gc = :wxGraphicsContext.create(dc)
        :wxGraphicsContext.setFont(gc, font(item), item.color)
        {_w, h, descent, _lead} = :wxGraphicsContext.getTextExtent(gc, ~c"Hg")
        :wxGraphicsContext.destroy(gc)
        box = {round(h), round(descent)}
        Process.put(key, box)
        box

      box ->
        box
    end
  end

  defp pen(color), do: cached({:pen, color}, fn -> :wxPen.new(color) end)

  # wx objects are made once per kind and kept: making one is a round trip, and nothing frees
  # them when they are dropped
  defp cached(key, make) do
    case Process.get(key) do
      nil ->
        value = make.()
        Process.put(key, value)
        value

      value ->
        value
    end
  end

  defp clip_to(gc, item, scroll) do
    if clip = Map.get(item, :clip),
      do: :wxGraphicsContext.clip(gc, clip.x, clip.y - scroll, clip.w, clip.h)
  end

  # the root element's background layers cover the whole window and scroll with the page
  defp draw_canvas_layers(dc, [%{type: :canvas, layers: [_ | _] = layers} | _], scroll) do
    gc = new_gc(dc)
    Enum.each(layers, &draw_layer(gc, &1, nil, scroll))
    :wxGraphicsContext.destroy(gc)
  end

  defp draw_canvas_layers(_dc, _items, _scroll), do: :ok

  # One background layer: a picture or gradient, repeated as the layer says, and
  # clipped to the area it paints into.
  defp draw_layer(gc, layer, radii, scroll) do
    {cx, cy, cw, ch} = layer.clip
    :wxGraphicsContext.clip(gc, cx, cy - scroll, cw, ch)
    tiles = Browser.Backgrounds.tiles(layer.tile, layer.repeat, layer.clip)
    {_, _, tw, th} = layer.tile

    case layer.kind do
      :image ->
        case :ets.lookup(@images, layer.url) do
          [{_url, bitmap}] ->
            for {x, y} <- tiles,
                do: :wxGraphicsContext.drawBitmap(gc, bitmap, x, y - scroll, tw, th)

          [] ->
            :ok
        end

      :svg ->
        for {x, y} <- tiles do
          :wxGraphicsContext.clip(gc, x, y - scroll, tw, th)
          draw_svg(gc, layer.ops, x, y - scroll)
          :wxGraphicsContext.resetClip(gc)
          :wxGraphicsContext.clip(gc, cx, cy - scroll, cw, ch)
        end

      :linear ->
        {x1, y1, x2, y2} = layer.line
        stops = gradient_stops(layer.stops)

        for {x, y} <- tiles do
          brush =
            :wxGraphicsContext.createLinearGradientBrush(
              gc,
              x + x1,
              y + y1 - scroll,
              x + x2,
              y + y2 - scroll,
              stops
            )

          fill_tile(gc, brush, {x, y - scroll, tw, th}, layer.clip, radii, scroll)
        end

      :radial ->
        {ox, oy} = layer.center
        {rx, ry} = layer.radii
        stops = gradient_stops(layer.stops)

        for {x, y} <- tiles do
          radial_tile(gc, stops, {x + ox, y + oy - scroll}, {rx, ry}, {x, y - scroll, tw, th})
        end
    end
  end

  # -- vector pictures ----------------------------------------------------------------

  # Pen widths are whole pixels, so strokes are drawn in a space four times as big and
  # scaled back down: quarter-pixel precision.
  @stroke_scale 4

  defp draw_svg(gc, ops, ox, oy) do
    Enum.each(ops, fn
      %{kind: :path} = op ->
        if op.fill, do: svg_fill(gc, op, ox, oy)
        if op.stroke, do: svg_stroke(gc, op, ox, oy)

      %{kind: :text} = op ->
        svg_text(gc, op, ox, oy)
    end)
  end

  defp svg_path(gc, segments, ox, oy, k) do
    path = :wxGraphicsContext.createPath(gc)

    Enum.each(segments, fn
      {:M, x, y} ->
        :wxGraphicsPath.moveToPoint(path, (ox + x) * k, (oy + y) * k)

      {:L, x, y} ->
        :wxGraphicsPath.addLineToPoint(path, (ox + x) * k, (oy + y) * k)

      {:C, x1, y1, x2, y2, x, y} ->
        :wxGraphicsPath.addCurveToPoint(
          path,
          {(ox + x1) * k, (oy + y1) * k},
          {(ox + x2) * k, (oy + y2) * k},
          {(ox + x) * k, (oy + y) * k}
        )

      :Z ->
        :wxGraphicsPath.closeSubpath(path)
    end)

    path
  end

  defp svg_fill(gc, %{fill: %{paint: paint, rule: rule}, segments: segments}, ox, oy) do
    :wxGraphicsContext.setBrush(gc, svg_brush(gc, paint, ox, oy))
    path = svg_path(gc, segments, ox, oy, 1)
    :wxGraphicsContext.fillPath(gc, path, [{:fillStyle, if(rule == :evenodd, do: 1, else: 2)}])
  end

  defp svg_brush(_gc, {:color, color}, _ox, _oy), do: :wxBrush.new(color)

  defp svg_brush(gc, {:linear, {x1, y1, x2, y2}, stops}, ox, oy) do
    :wxGraphicsContext.createLinearGradientBrush(
      gc,
      ox + x1,
      oy + y1,
      ox + x2,
      oy + y2,
      gradient_stops(stops)
    )
  end

  defp svg_brush(gc, {:radial, {cx, cy, r, fx, fy}, stops}, ox, oy) do
    :wxGraphicsContext.createRadialGradientBrush(
      gc,
      ox + fx,
      oy + fy,
      ox + cx,
      oy + cy,
      max(r, 0.01),
      gradient_stops(stops)
    )
  end

  # pens can't be gradients: a gradient stroke takes its first colour
  defp stroke_color({:color, color}), do: color
  defp stroke_color({_, _, [{_, color} | _]}), do: color

  defp svg_stroke(gc, %{stroke: stroke, segments: segments}, ox, oy) do
    k = @stroke_scale
    pen = :wxPen.new(stroke_color(stroke.paint), [{:width, max(round(stroke.width * k), 1)}])

    :wxPen.setCap(
      pen,
      case stroke.cap do
        :round -> 130
        :square -> 131
        :butt -> 132
      end
    )

    :wxPen.setJoin(
      pen,
      case stroke.join do
        :bevel -> 120
        :miter -> 121
        :round -> 122
      end
    )

    :wxGraphicsContext.setPen(gc, pen)
    :wxGraphicsContext.scale(gc, 1 / k, 1 / k)
    :wxGraphicsContext.strokePath(gc, svg_path(gc, segments, ox, oy, k))
    :wxGraphicsContext.scale(gc, k * 1.0, k * 1.0)
  end

  # SVG gives the baseline, anchored at the start, middle or end of the text
  defp svg_text(gc, op, ox, oy) do
    f =
      font(%{
        size: max(round(op.size), 1),
        bold: op.bold,
        italic: op.italic,
        mono: op.mono,
        family: Map.get(op, :family)
      })

    :wxGraphicsContext.setFont(gc, f, op.color)
    str = String.to_charlist(op.text)
    {w, h, descent, _} = :wxGraphicsContext.getTextExtent(gc, str)

    x =
      case op.anchor do
        :start -> op.x
        :middle -> op.x - w / 2
        :end -> op.x - w
      end

    :wxGraphicsContext.drawText(gc, str, ox + x, oy + op.y - (h - descent))
  end

  # a lone gradient that fills its whole area follows the box's rounded corners
  defp fill_tile(gc, brush, {x, y, w, h}, {cx, cy, cw, ch}, radii, scroll) do
    :wxGraphicsContext.setBrush(gc, brush)
    path = :wxGraphicsContext.createPath(gc)

    if radii && {x, y, w, h} == {cx, cy - scroll, cw, ch},
      do: outline(path, x, y, w, h, radii),
      else: :wxGraphicsPath.addRectangle(path, x, y, w, h)

    :wxGraphicsContext.fillPath(gc, path)
  end

  # a radial gradient is circular; an ellipse is drawn as a circle in a stretched space
  defp radial_tile(gc, stops, {cx, cy}, {rx, ry}, {x, y, w, h}) do
    if abs(rx - ry) < 0.5 do
      brush = :wxGraphicsContext.createRadialGradientBrush(gc, cx, cy, cx, cy, rx, stops)
      :wxGraphicsContext.setBrush(gc, brush)
      path = :wxGraphicsContext.createPath(gc)
      :wxGraphicsPath.addRectangle(path, x, y, w, h)
      :wxGraphicsContext.fillPath(gc, path)
    else
      k = rx / ry
      :wxGraphicsContext.translate(gc, cx, cy)
      :wxGraphicsContext.scale(gc, 1.0, ry / rx)
      brush = :wxGraphicsContext.createRadialGradientBrush(gc, 0.0, 0.0, 0.0, 0.0, rx, stops)
      :wxGraphicsContext.setBrush(gc, brush)
      path = :wxGraphicsContext.createPath(gc)
      :wxGraphicsPath.addRectangle(path, x - cx, (y - cy) * k, w, h * k)
      :wxGraphicsContext.fillPath(gc, path)
      :wxGraphicsContext.scale(gc, 1.0, k)
      :wxGraphicsContext.translate(gc, -cx, -cy)
    end
  end

  # [{position, {r, g, b, a}}] as gradient stops; the ends are the first and last colours
  defp gradient_stops(stops) do
    [{_, first} | _] = stops
    {_, last} = List.last(stops)
    gs = :wxGraphicsGradientStops.new([{:startCol, first}, {:endCol, last}])
    Enum.each(stops, fn {pos, color} -> :wxGraphicsGradientStops.add(gs, color, pos) end)
    gs
  end

  # a quarter ellipse is approximated by a cubic bezier with this handle length
  @kappa 0.5523

  defp outline(path, x, y, w, h, {{tlx, tly}, {trx, try_}, {brx, bry}, {blx, bly}}) do
    k = 1 - @kappa
    :wxGraphicsPath.moveToPoint(path, x + tlx, y)
    :wxGraphicsPath.addLineToPoint(path, x + w - trx, y)

    :wxGraphicsPath.addCurveToPoint(
      path,
      x + w - trx * k,
      y,
      x + w,
      y + try_ * k,
      x + w,
      y + try_
    )

    :wxGraphicsPath.addLineToPoint(path, x + w, y + h - bry)

    :wxGraphicsPath.addCurveToPoint(
      path,
      x + w,
      y + h - bry * k,
      x + w - brx * k,
      y + h,
      x + w - brx,
      y + h
    )

    :wxGraphicsPath.addLineToPoint(path, x + blx, y + h)

    :wxGraphicsPath.addCurveToPoint(
      path,
      x + blx * k,
      y + h,
      x,
      y + h - bly * k,
      x,
      y + h - bly
    )

    :wxGraphicsPath.addLineToPoint(path, x, y + tly)
    :wxGraphicsPath.addCurveToPoint(path, x, y + tly * k, x + tlx * k, y, x + tlx, y)
    :wxGraphicsPath.closeSubpath(path)
  end

  defp borders(gc, x, y, w, h, radii, %{w: {bt, br, bb, bl}, c: {tc, rc, bc, lc}} = border) do
    {{tlx, tly}, {trx, try_}, {brx, bry}, {blx, bly}} = radii
    {st, sr, sb, sl} = Map.get(border, :s) || {:solid, :solid, :solid, :solid}

    # straight parts of the four sides; the top one has a gap where a fieldset's legend is
    {g0, g1} = Map.get(border, :gap) || {0, 0}
    top0 = x + tlx
    top1 = x + w - trx
    g0 = g0 |> max(top0) |> min(top1)
    g1 = g1 |> max(g0) |> min(top1)

    if g1 > g0 do
      strip(gc, tc, st, :h, top0, y, g0 - top0, bt, tlx > 0, false)
      strip(gc, tc, st, :h, g1, y, top1 - g1, bt, false, trx > 0)
    else
      strip(gc, tc, st, :h, top0, y, top1 - top0, bt, tlx > 0, trx > 0)
    end

    strip(gc, bc, sb, :h, x + blx, y + h - bb, w - blx - brx, bb, blx > 0, brx > 0)
    strip(gc, lc, sl, :v, x, y + tly, bl, h - tly - bly, tly > 0, bly > 0)
    strip(gc, rc, sr, :v, x + w - br, y + try_, br, h - try_ - bry, try_ > 0, bry > 0)

    # corners: local coordinates run from the corner point inwards along (dx, dy)
    corner(gc, pick(tc, bt, lc, bl), x, y, 1, 1, {tlx, tly}, bl, bt)
    corner(gc, pick(tc, bt, rc, br), x + w, y, -1, 1, {trx, try_}, br, bt)
    corner(gc, pick(bc, bb, rc, br), x + w, y + h, -1, -1, {brx, bry}, br, bb)
    corner(gc, pick(bc, bb, lc, bl), x, y + h, 1, -1, {blx, bly}, bl, bb)
  end

  # colour of the thicker of the two sides meeting at a corner (horizontal wins ties)
  defp pick(hc, ht, vc, vt), do: if(ht >= vt, do: hc || vc, else: vc || hc)

  defp strip(_gc, nil, _style, _dir, _x, _y, _w, _h, _arc0, _arc1), do: :ok
  defp strip(_gc, _c, _style, _dir, _x, _y, w, h, _arc0, _arc1) when w <= 0 or h <= 0, do: :ok

  # a dashed or dotted side: dashes 3 thick (dots 1) with gaps as long, spread to fit the side.
  # A rounded corner is drawn solid, so it counts as a dash: the side starts (ends) with a gap
  # where it meets one (`arc0`, `arc1`).
  defp strip(gc, color, style, dir, x, y, w, h, arc0, arc1) when style in [:dashed, :dotted] do
    {len, t} = if dir == :h, do: {w, h}, else: {h, w}
    {dash, gap} = if style == :dashed, do: {3 * t, 3 * t}, else: {t, t}
    {lead, trail} = {if(arc0, do: gap, else: 0), if(arc1, do: gap, else: 0)}

    {x, y, w, h, len} =
      if len - lead - trail >= dash do
        len = len - lead - trail

        if dir == :h,
          do: {x + lead, y, len, h, len},
          else: {x, y + lead, w, len, len}
      else
        {x, y, w, h, len}
      end

    n = max(round((len + gap) / (dash + gap)), 1)
    dash_len = if n == 1, do: len, else: (len - (n - 1) * gap) / n

    :wxGraphicsContext.setBrush(gc, :wxBrush.new(color))
    path = :wxGraphicsContext.createPath(gc)

    for i <- 0..(n - 1) do
      at = i * (dash_len + gap)

      if dir == :h,
        do: :wxGraphicsPath.addRectangle(path, x + at, y, dash_len, h),
        else: :wxGraphicsPath.addRectangle(path, x, y + at, w, dash_len)
    end

    :wxGraphicsContext.fillPath(gc, path)
  end

  defp strip(gc, color, _style, _dir, x, y, w, h, _arc0, _arc1) do
    :wxGraphicsContext.setBrush(gc, :wxBrush.new(color))
    path = :wxGraphicsContext.createPath(gc)
    :wxGraphicsPath.addRectangle(path, x, y, w, h)
    :wxGraphicsContext.fillPath(gc, path)
  end

  defp corner(_gc, nil, _cx, _cy, _dx, _dy, _r, _bv, _bh), do: :ok
  defp corner(_gc, _c, _cx, _cy, _dx, _dy, {rx, ry}, _bv, _bh) when rx <= 0 or ry <= 0, do: :ok

  # `bv` is the thickness of the vertical side at this corner, `bh` of the horizontal
  defp corner(gc, color, cx, cy, dx, dy, {rx, ry}, bv, bh) do
    k = 1 - @kappa
    irx = max(rx - bv, 0)
    iry = max(ry - bh, 0)
    m = fn u, v -> {cx + dx * u, cy + dy * v} end
    {ox1, oy1} = m.(0, ry)
    {ox2, oy2} = m.(rx, 0)
    {c1x, c1y} = m.(0, ry * k)
    {c2x, c2y} = m.(rx * k, 0)
    {ax, ay} = m.(bv + irx, bh)
    {bx, by} = m.(bv, bh + iry)
    {d1x, d1y} = m.(bv + irx - irx * @kappa, bh)
    {d2x, d2y} = m.(bv, bh + iry - iry * @kappa)

    :wxGraphicsContext.setBrush(gc, :wxBrush.new(color))
    path = :wxGraphicsContext.createPath(gc)
    :wxGraphicsPath.moveToPoint(path, ox1, oy1)
    :wxGraphicsPath.addCurveToPoint(path, c1x, c1y, c2x, c2y, ox2, oy2)
    :wxGraphicsPath.addLineToPoint(path, ax, ay)
    :wxGraphicsPath.addCurveToPoint(path, d1x, d1y, d2x, d2y, bx, by)
    :wxGraphicsPath.closeSubpath(path)
    :wxGraphicsContext.fillPath(gc, path)
  end

  # -- hit testing -------------------------------------------------------------

  @link_band 64

  @doc """
  Indexes the links of a laid out page by horizontal band, so `link_at/3` looks at the few
  links near the pointer instead of every item. Each band keeps its links in paint order.
  """
  # How far a sticky or fixed item is moved down the page when the window is scrolled to
  # `scroll`: nothing for ordinary items; a sticky box once the page has scrolled past the
  # point where it would leave the window; a fixed box all the way.
  def stick_shift(%{stick: :fixed}, scroll), do: scroll

  def stick_shift(%{stick: %{top: top, y0: y0} = stick}, scroll) do
    shift = max(round(scroll + top - y0), 0)

    case stick do
      # it stops when its bottom reaches the bottom of the block it is in
      %{limit: limit, h: h} when is_number(limit) -> min(shift, max(round(limit - (y0 + h)), 0))
      _ -> shift
    end
  end

  def stick_shift(_item, _scroll), do: 0

  # (sticky and fixed items are found by `sticky_hit/4`: their place depends on the scroll)
  def links(items) do
    items
    |> Enum.reduce(%{}, fn
      %{stick: _}, acc ->
        acc

      # transformed boxes are drawn somewhere else than they were laid out: see `sticky_hit/4`
      %{xform: _}, acc ->
        acc

      %{type: type, href: href} = it, acc
      when type in [:text, :image, :svg] and is_binary(href) ->
        first = band(it.y)
        last = band(it.y + it.h + 4)
        Enum.reduce(first..last//1, acc, fn b, acc -> Map.update(acc, b, [it], &[it | &1]) end)

      _, acc ->
        acc
    end)
    |> Map.new(fn {b, its} -> {b, Enum.reverse(its)} end)
  end

  @doc "The href of the first link in the index `links` (see `links/1`) at page position `{x, y}`, or nil."
  def link_at(links, x, y) do
    links
    |> Map.get(band(y), [])
    |> Enum.find_value(fn it ->
      if inside?(x, y, it.x, it.y, it.w, it.h + 4) and clipped_in?(it, x, y), do: it.href
    end)
  end

  defp band(y), do: floor(y / @link_band)

  defp inside?(px, py, x, y, w, h), do: px >= x and px <= x + w and py >= y and py <= y + h

  # a link scrolled out of its clipping box can't be clicked
  defp clipped_in?(%{clip: c}, x, y), do: inside?(x, y, c.x, c.y, c.w, c.h)
  defp clipped_in?(_, _, _), do: true

  def set_url_text(%{url: url} = ui, text) do
    hide_suggestions(ui)
    :wxTextCtrl.setValue(url, String.to_charlist(text))
  end

  @doc "Puts text in the address bar and leaves the suggestions as they are."
  def put_url_text(%{url: url}, text), do: :wxTextCtrl.setValue(url, String.to_charlist(text))

  @row_h 22

  @doc "Shows the address suggestions (`[{url, title}]`) under the address bar; none hides them."
  def show_suggestions(ui, []), do: hide_suggestions(ui)

  def show_suggestions(%{suggest: list, toolbar: toolbar, url: url}, items) do
    {x, _} = :wxWindow.getPosition(url)
    {w, _} = :wxWindow.getSize(url)
    {_, y} = :wxWindow.getSize(toolbar)
    :wxListBox.clear(list)

    for {u, title} <- items do
      label = if title in [nil, ""], do: u, else: "#{title} — #{u}"
      :wxListBox.append(list, String.to_charlist(label))
    end

    :wxWindow.setSize(list, x, y, w, min(length(items), 8) * @row_h + 6)
    :wxWindow.raise(list)
    :wxWindow.show(list)
  end

  def hide_suggestions(%{suggest: list}), do: :wxWindow.hide(list)

  @doc "Highlights suggestion `i` (-1: none)."
  def select_suggestion(%{suggest: list}, -1) do
    case :wxListBox.getSelection(list) do
      -1 -> :ok
      i -> :wxListBox.deselect(list, i)
    end
  end

  def select_suggestion(%{suggest: list}, i), do: :wxListBox.setSelection(list, i)

  @doc "Shows the tab strip: the tabs' titles and which one is active."
  def set_tabs(%{tabs: tabs}, titles, active) do
    Browser.TabStrip.put(titles, active)
    :wxWindow.refresh(tabs)
  end

  def tabs_width(%{tabs: tabs}), do: tabs |> :wxWindow.getClientSize() |> elem(0)

  def set_title(%{frame: f}, title), do: :wxFrame.setTitle(f, String.to_charlist(title))
  def set_status(%{frame: f}, text), do: :wxFrame.setStatusText(f, String.to_charlist(text))
  def enable(widget, bool), do: :wxWindow.enable(widget, enable: bool)
  def refresh(%{panel: p}), do: :wxWindow.refresh(p)

  @doc "Sets the mouse cursor over the page: `:arrow`, `:hand` or `:text`."
  def set_cursor(%{panel: p, cursors: cursors}, kind) do
    kind = if kind in [true, :hand], do: :hand, else: if(kind == :text, do: :text, else: :arrow)
    :wxWindow.setCursor(p, Map.fetch!(cursors, kind))
  end

  @doc "Moves keyboard focus to the page, so key events reach it."
  def focus_page(%{panel: p}), do: :wxWindow.setFocus(p)

  # -- images ------------------------------------------------------------------------

  @doc """
  Decodes image bytes (PNG, JPEG, GIF or BMP) into a bitmap the painter can draw, kept
  under `url`. Returns `{:ok, width, height}` or `:error`. The toolkit reads from files,
  so the bytes pass through a temporary one.
  """
  def load_image(url, bytes, format) do
    path =
      Path.join(System.tmp_dir!(), "browser-pic-#{System.unique_integer([:positive])}.#{format}")

    try do
      File.write!(path, bytes)
      image = :wxImage.new(String.to_charlist(path))

      if :wxImage.isOk(image) do
        {w, h} = {:wxImage.getWidth(image), :wxImage.getHeight(image)}
        bitmap = :wxBitmap.new(image)
        :wxImage.destroy(image)
        :ets.insert(@images, {url, bitmap})
        if w > 0 and h > 0, do: {:ok, w, h}, else: :error
      else
        :error
      end
    rescue
      _ -> :error
    after
      File.rm(path)
    end
  end

  # -- controls --------------------------------------------------------------------

  @doc "The id of the form control at page position `{x, y}` (the smallest if they nest), or nil."
  # What the sticky and fixed `items` (with the window scrolled to `scroll`) have at window
  # point `{x, y}`: `{:link, href}`, `{:control, cid, page_y}` (with the y the control has on
  # the page, for caret placement), `:cover` for anything else they paint there, or nil.
  def sticky_hit([], _x, _y, _scroll), do: nil

  def sticky_hit(items, x, y, scroll) do
    at =
      for it <- items,
          Map.has_key?(it, :w) and Map.has_key?(it, :h),
          shift = stick_shift(it, scroll),
          # the point on the page, as laid out: before sticking and before any transformation
          {px, py} <- [item_space(it, x, y + scroll - shift)],
          inside?(
            px,
            py,
            it.x,
            it.y,
            it.w,
            it.h + if(it.type in [:text, :image, :svg], do: 4, else: 0)
          ),
          Map.has_key?(it, :xform) or clipped_in?(it, px, py) do
        {it, py}
      end

    # the topmost (last painted) item decides; controls and links before plain boxes
    at = Enum.reverse(at)

    control =
      Enum.find_value(at, fn {it, py} ->
        if Map.get(it, :cid) != nil, do: {:control, it.cid, py}
      end)

    link =
      Enum.find_value(at, fn {it, _} ->
        if it.type in [:text, :image, :svg] and is_binary(Map.get(it, :href)),
          do: {:link, it.href}
      end)

    # a stuck box also keeps the page below it from being clicked; a transformed one does not
    cover = Enum.any?(at, fn {it, _} -> Map.has_key?(it, :stick) end)

    cond do
      control -> control
      link -> link
      cover -> :cover
      true -> nil
    end
  end

  # where the item is, for the point `{x, y}` on the page as it is drawn
  defp item_space(%{xform: matrices}, x, y) do
    case Browser.Transform.unapply(matrices, x, y) do
      nil -> :none
      point -> point
    end
    |> case do
      :none -> {-1.0e9, -1.0e9}
      point -> point
    end
  end

  defp item_space(_item, x, y), do: {x, y}

  def control_at(controls, x, y) do
    controls
    |> Enum.filter(fn {_cid, b} ->
      x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h
    end)
    |> Enum.min_by(fn {_cid, b} -> b.w * b.h end, fn -> nil end)
    |> case do
      nil -> nil
      {cid, _} -> cid
    end
  end

  # -- keyboard and clipboard ------------------------------------------------------

  @doc "Reads a wx key event into the plain map `Browser.Interact.key/1` expects."
  def key_event(
        wxKey(
          keyCode: code,
          uniChar: char,
          controlDown: ctrl,
          metaDown: meta,
          shiftDown: shift,
          altDown: alt
        )
      ) do
    %{code: code, char: char, ctrl?: ctrl, meta?: meta, shift?: shift, alt?: alt}
  end

  @doc "Puts `text` on the clipboard."
  def set_clipboard_text(text) do
    clip = :wxClipboard.get()

    if :wxClipboard.open(clip) do
      :wxClipboard.setData(clip, :wxTextDataObject.new([{:text, String.to_charlist(text)}]))
      :wxClipboard.close(clip)
    end

    :ok
  end

  @doc "The text on the clipboard, or \"\"."
  def clipboard_text do
    clip = :wxClipboard.get()

    if :wxClipboard.open(clip) do
      data = :wxTextDataObject.new()
      text = if :wxClipboard.getData(clip, data), do: :wxTextDataObject.getText(data), else: []
      :wxClipboard.close(clip)
      List.to_string(text)
    else
      ""
    end
  end

  # -- select popup ----------------------------------------------------------------

  @menu_base 1000

  @doc """
  Pops up a menu of `labels` at page position `{x, y}` (the chosen one is ticked). The
  choice arrives as a `command_menu_selected` event whose id is `menu_base() + index`.
  """
  def popup_menu(%{panel: p}, {x, y}, labels, selected) do
    menu = :wxMenu.new()

    labels
    |> Enum.with_index()
    |> Enum.each(fn {label, i} ->
      text = if i == selected, do: "✓ " <> label, else: "   " <> label
      :wxMenu.append(menu, @menu_base + i, String.to_charlist(text))
    end)

    :wxMenu.connect(menu, :command_menu_selected)
    :wxWindow.popupMenu(p, menu, x, y)
    :ok
  end

  def menu_base, do: @menu_base

  # -- context menu -------------------------------------------------------------------

  @context_base 2000

  @doc """
  Pops up the right-click menu at window position `{x, y}`. `entries` are `{label, enabled?}`
  or `:separator`; the choice arrives as a `command_menu_selected` event whose id is
  `context_base() + index` (separators count). It is a native menu, so it follows the
  system theme.
  """
  def context_menu(%{panel: p}, {x, y}, entries) do
    menu = :wxMenu.new()

    entries
    |> Enum.with_index()
    |> Enum.each(fn
      {:separator, _} ->
        :wxMenu.appendSeparator(menu)

      {{label, enabled?}, i} ->
        :wxMenu.append(menu, @context_base + i, String.to_charlist(label))
        unless enabled?, do: :wxMenu.enable(menu, @context_base + i, false)
    end)

    :wxMenu.connect(menu, :command_menu_selected)
    :wxWindow.popupMenu(p, menu, x, y)
    :ok
  end

  def context_base, do: @context_base

  @doc """
  The topmost drawn item at page position `{x, y}` that belongs to a DOM element (it has a
  `nid`), or nil. Sticky, fixed and transformed boxes are not found.
  """
  def item_at(items, x, y) do
    items
    |> Enum.filter(fn it ->
      not Map.has_key?(it, :stick) and not Map.has_key?(it, :xform) and
        Map.get(it, :nid) != nil and
        inside?(x, y, it.x, it.y, Map.get(it, :w, 0), Map.get(it, :h, 0)) and
        clipped_in?(it, x, y)
    end)
    |> List.last()
  end
end
