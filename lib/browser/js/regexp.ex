defmodule Browser.JS.RegExp do
  @moduledoc """
  Regular expressions for the JavaScript runtime, on top of Erlang's `:re` (PCRE).

  A RegExp object is a heap object with class `:regexp`; `source`, `flags`, `global` and so on
  are hidden properties and `lastIndex` is a plain one. Positions are code points, like every
  other string index in the runtime.
  """

  import Browser.JS.Interp, except: [get: 2, put: 3]
  alias Browser.JS.{Interp, Props, Str}

  defp arg(args, i), do: Enum.at(args, i, :undefined)

  # ── building ───────────────────────────────────────────────

  @doc "A new RegExp object."
  def new(source, flags) do
    {re, names} = compile(source, flags)

    obj =
      {:obj,
       alloc(%{
         class: :regexp,
         src: source,
         fl: flags,
         re: re,
         names: names,
         props: %{},
         keys: [],
         proto: proto(:regexp)
       })}

    put_hidden(obj, "lastIndex", 0.0)
    {:obj, id} = obj
    o = deref(id)
    store(id, Map.put(o, :attrs, %{"lastIndex" => %{w: true, c: false, e: false}}))
    obj
  end

  def regexp?({:obj, id}), do: match?(%{class: :regexp}, deref(id))
  def regexp?(_), do: false

  defp flags_of({:obj, id}) do
    case deref(id) do
      %{fl: fl} -> fl
      _ -> throw_error("TypeError", "RegExp method called on incompatible receiver")
    end
  end

  defp flags_of(_), do: throw_error("TypeError", "RegExp method called on incompatible receiver")
  defp source_of({:obj, id}), do: deref(id).src
  defp flag?(re_obj, f), do: String.contains?(flags_of(re_obj), f)

  # the pattern text as `source` shows it: `/` and line terminators escaped, `(?:)` when empty
  defp escape_source(""), do: "(?:)"
  defp escape_source(src), do: escape_source(String.graphemes(src), false, [])

  defp escape_source([], _, acc), do: acc |> Enum.reverse() |> Enum.join()
  defp escape_source(["\\", c | rest], cls, acc), do: escape_source(rest, cls, [c, "\\" | acc])
  defp escape_source(["[" | rest], _, acc), do: escape_source(rest, true, ["[" | acc])
  defp escape_source(["]" | rest], _, acc), do: escape_source(rest, false, ["]" | acc])
  defp escape_source(["/" | rest], false, acc), do: escape_source(rest, false, ["\\/" | acc])
  defp escape_source(["\n" | rest], c, acc), do: escape_source(rest, c, ["\\n" | acc])
  defp escape_source(["\r" | rest], c, acc), do: escape_source(rest, c, ["\\r" | acc])
  defp escape_source(["\u2028" | rest], c, acc), do: escape_source(rest, c, ["\\u2028" | acc])
  defp escape_source(["\u2029" | rest], c, acc), do: escape_source(rest, c, ["\\u2029" | acc])
  defp escape_source([ch | rest], c, acc), do: escape_source(rest, c, [ch | acc])

  @doc "Checks a literal at parse time: `:ok` or `{:error, message}` (an early SyntaxError)."
  def validate(source, flags) do
    flag_list = String.graphemes(flags)

    cond do
      Enum.any?(flag_list, &(&1 not in ~w(d g i m s u v y))) or
          length(flag_list) != length(Enum.uniq(flag_list)) ->
        {:error, "Invalid regular expression flags"}

      true ->
        case build(source, flags) do
          {:ok, _} -> :ok
          {:error, msg} -> {:error, "Invalid regular expression: /#{source}/: #{msg}"}
        end
    end
  end

  defp compile(source, flags) do
    key = {:js_re, source, flags}

    case Process.get(key) do
      nil ->
        case build(source, flags) do
          {:ok, res} ->
            Process.put(key, res)
            res

          {:error, msg} ->
            throw_error("SyntaxError", "Invalid regular expression: /#{source}/: #{msg}")
        end

      res ->
        res
    end
  end

  defp build(source, flags) do
    if String.contains?(flags, "u") and String.contains?(flags, "v"),
      do: {:error, "the u and v flags can not be combined"},
      else: build_pattern(source, flags)
  end

  defp build_pattern(source, flags) do
    opts =
      [:unicode, :dollar_endonly] ++
        for(
          {f, o} <- [{"i", :caseless}, {"m", :multiline}, {"s", :dotall}],
          String.contains?(flags, f),
          do: o
        )

    {renamed, names} = rename_groups(source)

    pattern =
      if String.contains?(flags, "v"),
        do: Browser.JS.RegExpSets.translate(renamed, &translate/1),
        else: translate(renamed)

    case :re.compile(pattern, opts) do
      {:ok, re} ->
        {:ok, {re, names}}

      {:error, {msg, _}} ->
        {:error, msg}
    end
  catch
    {:re_error, msg} -> {:error, msg}
  end

  # Named groups: JavaScript names (`$`, unicode letters, `\\u{..}` escapes) are not all valid
  # in PCRE, so each group is renamed `g<number>` and `\\k<name>` follows. Returns the new
  # pattern and `[{group number, name}]` in pattern order.
  defp rename_groups(source) do
    {count, names} = scan_groups(source, 0, false, [])

    if names == [] do
      {source, {count, []}}
    else
      by_name = Map.new(names, fn {i, n} -> {n, i} end)
      {rewrite_groups(source, false, by_name, []), {count, names}}
    end
  end

  # pass 1: the capture groups (counted) and the names of the named ones
  defp scan_groups("", n, _cls, acc), do: {n, Enum.reverse(acc)}

  defp scan_groups(<<?\\, _::utf8, rest::binary>>, n, cls, acc),
    do: scan_groups(rest, n, cls, acc)

  defp scan_groups("[" <> rest, n, false, acc), do: scan_groups(rest, n, true, acc)
  defp scan_groups("]" <> rest, n, true, acc), do: scan_groups(rest, n, false, acc)

  defp scan_groups("(?<" <> rest, n, false, acc) do
    case rest do
      "=" <> r ->
        scan_groups(r, n, false, acc)

      "!" <> r ->
        scan_groups(r, n, false, acc)

      _ ->
        unless String.contains?(rest, ">"), do: bad_name()
        {raw, after_name} = split_name(rest)
        name = decode_name(raw)
        unless valid_name?(name), do: bad_name()
        if Enum.any?(acc, fn {_, existing} -> existing == name end), do: bad_name()
        scan_groups(after_name, n + 1, false, [{n + 1, name} | acc])
    end
  end

  defp scan_groups("(?" <> rest, n, false, acc), do: scan_groups(rest, n, false, acc)
  defp scan_groups("(" <> rest, n, false, acc), do: scan_groups(rest, n + 1, false, acc)
  defp scan_groups(<<_::utf8, rest::binary>>, n, cls, acc), do: scan_groups(rest, n, cls, acc)
  defp scan_groups(<<_, rest::binary>>, n, cls, acc), do: scan_groups(rest, n, cls, acc)

  defp bad_name, do: throw({:re_error, "Invalid capture group name"})

  # an identifier: ID_Start, `$` or `_`, then those and ID_Continue and ZWNJ/ZWJ
  defp valid_name?(name) do
    Regex.match?(
      ~r/\A[\p{L}\p{Nl}$_][\p{L}\p{Nl}\p{Mn}\p{Mc}\p{Nd}\p{Pc}$_\x{200C}\x{200D}]*\z/u,
      name
    )
  end

  defp split_name(rest) do
    case String.split(rest, ">", parts: 2) do
      [raw, after_name] -> {raw, after_name}
      _ -> {rest, ""}
    end
  end

  # `\u0041`, `\u{41}` and surrogate pairs in a group name
  defp decode_name(raw), do: decode_name(raw, [])
  defp decode_name("", acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp decode_name("\\u{" <> rest, acc) do
    [hex, r] = String.split(rest, "}", parts: 2)
    decode_name(r, [<<String.to_integer(hex, 16)::utf8>> | acc])
  rescue
    _ -> bad_name()
  end

  defp decode_name(<<"\\u", hex::binary-size(4), rest::binary>>, acc) do
    with {hi, ""} when hi in 0xD800..0xDBFF <- Integer.parse(hex, 16),
         <<"\\u", lo_hex::binary-size(4), after_pair::binary>> <- rest,
         {lo, ""} when lo in 0xDC00..0xDFFF <- Integer.parse(lo_hex, 16) do
      decode_name(after_pair, [<<0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00)::utf8>> | acc])
    else
      _ ->
        case Integer.parse(hex, 16) do
          {n, ""} when n not in 0xD800..0xDFFF -> decode_name(rest, [<<n::utf8>> | acc])
          _ -> bad_name()
        end
    end
  end

  defp decode_name(<<c::utf8, rest::binary>>, acc), do: decode_name(rest, [<<c::utf8>> | acc])
  defp decode_name(<<_, rest::binary>>, acc), do: decode_name(rest, acc)

  # pass 2: the definitions and the references use the new names
  defp rewrite_groups("", _cls, _by, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp rewrite_groups(<<"\\k<", rest::binary>>, cls, by, acc) do
    unless String.contains?(rest, ">"), do: bad_name()
    {raw, after_name} = split_name(rest)

    case Map.fetch(by, decode_name(raw)) do
      {:ok, i} -> rewrite_groups(after_name, cls, by, ["\\k<g#{i}>" | acc])
      :error -> bad_name()
    end
  end

  defp rewrite_groups(<<?\\, c::utf8, rest::binary>>, cls, by, acc),
    do: rewrite_groups(rest, cls, by, [<<?\\, c::utf8>> | acc])

  defp rewrite_groups("[" <> rest, false, by, acc),
    do: rewrite_groups(rest, true, by, ["[" | acc])

  defp rewrite_groups("]" <> rest, true, by, acc),
    do: rewrite_groups(rest, false, by, ["]" | acc])

  defp rewrite_groups("(?<" <> rest, false, by, acc) do
    case rest do
      <<c, _::binary>> when c in ~c"=!" ->
        rewrite_groups(rest, false, by, ["(?<" | acc])

      _ ->
        {raw, after_name} = split_name(rest)
        i = Map.fetch!(by, decode_name(raw))
        rewrite_groups(after_name, false, by, ["(?<g#{i}>" | acc])
    end
  end

  defp rewrite_groups(<<c::utf8, rest::binary>>, cls, by, acc),
    do: rewrite_groups(rest, cls, by, [<<c::utf8>> | acc])

  defp rewrite_groups(<<c, rest::binary>>, cls, by, acc),
    do: rewrite_groups(rest, cls, by, [<<c>> | acc])

  # JavaScript syntax that PCRE spells differently
  defp translate(source), do: translate(source, false, [])

  defp translate("", _cls, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp translate("\\u{" <> rest, cls, acc) do
    [hex, rest] = String.split(rest, "}", parts: 2)
    translate(rest, cls, ["\\x{#{hex}}" | acc])
  end

  defp translate(<<"\\u", hex::binary-size(4), rest::binary>>, cls, acc) do
    case Integer.parse(hex, 16) do
      {hi, ""} when hi in 0xD800..0xDBFF ->
        # an escaped surrogate pair is the one character it stands for
        with <<"\\u", lo_hex::binary-size(4), after_pair::binary>> <- rest,
             {lo, ""} when lo in 0xDC00..0xDFFF <- Integer.parse(lo_hex, 16) do
          cp = 0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00)
          translate(after_pair, cls, ["\\x{#{Integer.to_string(cp, 16)}}" | acc])
        else
          _ -> lone_surrogate(rest, cls, acc)
        end

      {lo, ""} when lo in 0xDC00..0xDFFF ->
        lone_surrogate(rest, cls, acc)

      _ ->
        translate(rest, cls, ["\\x{#{hex}}" | acc])
    end
  end

  defp translate("\\/" <> rest, cls, acc), do: translate(rest, cls, ["/" | acc])

  defp translate(<<?\\, c::utf8, rest::binary>>, cls, acc),
    do: translate(rest, cls, [<<?\\, c::utf8>> | acc])

  defp translate("[^]" <> rest, false, acc), do: translate(rest, false, ["[\\s\\S]" | acc])
  defp translate("[]" <> rest, false, acc), do: translate(rest, false, ["(?!)" | acc])
  defp translate("[" <> rest, false, acc), do: translate(rest, true, ["[" | acc])
  defp translate("[" <> rest, true, acc), do: translate(rest, true, ["\\[" | acc])
  defp translate("]" <> rest, true, acc), do: translate(rest, false, ["]" | acc])

  defp translate(<<c::utf8, rest::binary>>, cls, acc),
    do: translate(rest, cls, [<<c::utf8>> | acc])

  # a character no string has: what a surrogate in a class becomes (a class cannot be left empty)
  @never "\\x{FFFF}"

  # A string here is made of whole characters, so a lone surrogate in a pattern never matches:
  # outside a class that is `(?!)`, inside one the character (or a range of them) is left out.
  defp lone_surrogate(rest, false, acc), do: translate(rest, false, ["(?!)" | acc])

  defp lone_surrogate(<<"-\\u", hex::binary-size(4), after_range::binary>> = rest, true, acc) do
    case Integer.parse(hex, 16) do
      {n, ""} when n in 0xD800..0xDFFF -> translate(after_range, true, [@never | acc])
      {n, ""} when n > 0xDFFF -> translate(after_range, true, ["\\x{E000}-\\x{#{hex}}" | acc])
      _ -> translate(rest, true, [@never | acc])
    end
  end

  defp lone_surrogate(rest, true, acc), do: translate(rest, true, [@never | acc])

  # ── matching ───────────────────────────────────────────────

  # -> nil | %{start, stop, groups: [binary | :undefined], named: %{name => binary | :undefined}}
  # (code point positions; `from` is a code point index)
  defp match_at(re_obj, subject, from) do
    %{re: re, names: names} = deref(elem(re_obj, 1))
    from_byte = byte_of(subject, from)
    sticky? = flag?(re_obj, "y")

    case :re.run(subject, re, [{:capture, :all, :index}, {:offset, from_byte}]) do
      {:match, [{start, len} | caps]} when not sticky? or start == from_byte ->
        {count, named_list} = names

        # (PCRE leaves out trailing groups that did not take part)
        groups =
          for {s, l} <- caps do
            if s < 0, do: :undefined, else: binary_part(subject, s, l)
          end

        groups = groups ++ List.duplicate(:undefined, count - length(groups))

        named = named_groups(named_list, groups)

        # (the code point spans of every group, only worked out for the `d` flag)
        spans =
          if flag?(re_obj, "d") do
            spans =
              for {s, l} <- [{start, len} | caps] do
                if s < 0,
                  do: :undefined,
                  else:
                    {cp_count(binary_part(subject, 0, s)),
                     cp_count(binary_part(subject, 0, s + l))}
              end

            spans ++ List.duplicate(:undefined, count + 1 - length(spans))
          end

        %{
          spans: spans,
          start: cp_count(binary_part(subject, 0, start)),
          stop: cp_count(binary_part(subject, 0, start + len)),
          text: binary_part(subject, start, len),
          groups: groups,
          named: named,
          names: named_list
        }

      _ ->
        nil
    end
  end

  # `[{name, value}]` of the named groups, in pattern order; nil without any
  defp named_groups([], _), do: nil

  defp named_groups(names, groups),
    do: for({i, name} <- names, do: {name, Enum.at(groups, i - 1)})

  defp byte_of(subject, cp) do
    byte_of(subject, cp, 0)
  end

  # byte offset of the code point index `n` (strings are indexed by code point)
  defp byte_of(_, n, acc) when n <= 0, do: acc
  defp byte_of(<<c::utf8, rest::binary>>, n, acc), do: byte_of(rest, n - 1, acc + utf8_size(c))
  defp byte_of(<<>>, _, acc), do: acc
  defp byte_of(<<_, rest::binary>>, n, acc), do: byte_of(rest, n - 1, acc + 1)

  defp utf8_size(c) when c < 0x80, do: 1
  defp utf8_size(c) when c < 0x800, do: 2
  defp utf8_size(c) when c < 0x10000, do: 3
  defp utf8_size(_), do: 4

  # the number of code points (what `.length` and match positions count)
  defp cp_count(bin), do: cp_count(bin, 0)
  defp cp_count(<<_::utf8, rest::binary>>, n), do: cp_count(rest, n + 1)
  defp cp_count(<<>>, n), do: n
  defp cp_count(<<_, rest::binary>>, n), do: cp_count(rest, n + 1)

  defp match_array(m, subject) do
    arr = new_array([m.text | m.groups])
    Interp.define_data(arr, "index", m.start * 1.0)
    Interp.define_data(arr, "input", subject)

    groups =
      case m.named do
        nil -> :undefined
        named -> new_object(named, :null)
      end

    Interp.define_data(arr, "groups", groups)
    if m.spans, do: put_hidden_indices(arr, m)
    arr
  end

  # `indices` of a match made with the `d` flag: [start, end] pairs, and `groups` by name
  defp put_hidden_indices(arr, m) do
    pair = fn
      :undefined -> :undefined
      {a, b} -> new_array([a * 1.0, b * 1.0])
    end

    indices = new_array(Enum.map(m.spans, pair))

    groups =
      case m.named do
        nil ->
          :undefined

        _named ->
          new_object(for({i, name} <- m.names, do: {name, pair.(Enum.at(m.spans, i))}), :null)
      end

    Interp.define_data(indices, "groups", groups)
    Interp.define_data(arr, "indices", indices)
  end

  # ── the RegExp protocol (exec, @@match, @@replace, ...) ────

  @sym_match {:symbol, :match, "Symbol.match"}
  @sym_match_all {:symbol, :matchAll, "Symbol.matchAll"}
  @sym_replace {:symbol, :replace, "Symbol.replace"}
  @sym_search {:symbol, :search, "Symbol.search"}
  @sym_split {:symbol, :split, "Symbol.split"}
  @sym_species {:symbol, :species, "Symbol.species"}

  defp tolen(v), do: v |> to_int() |> max(0) |> min(9_007_199_254_740_991)

  defp strict_set(o, key, v) do
    unless Props.ordinary_set(o, key, v, o),
      do: throw_error("TypeError", "Cannot assign to read only property '#{key}'")

    :ok
  end

  defp object?({:obj, _}), do: true
  defp object?(_), do: false

  defp require_object(v) do
    unless object?(v), do: throw_error("TypeError", "RegExp method called on a non-object")
    v
  end

  defp same_value?(a, b) when is_number(a) and is_number(b),
    do: <<a * 1.0::float-64>> == <<b * 1.0::float-64>>

  defp same_value?(a, b), do: a === b

  # GetMethod: nil when undefined or null
  defp get_method(obj, key) do
    case Interp.get(obj, key) do
      v when v in [:undefined, :null] ->
        nil

      f ->
        unless function?(f), do: throw_error("TypeError", "method is not a function")
        f
    end
  end

  @doc "IsRegExp."
  def is_regexp({:obj, _} = v) do
    case Interp.get(v, @sym_match) do
      :undefined -> regexp?(v)
      m -> truthy(m)
    end
  end

  def is_regexp(_), do: false

  @doc "RegExpBuiltinExec: the match array or null, advancing `lastIndex` for g/y regexps."
  def exec(re_obj, subject) do
    last = tolen(Interp.get(re_obj, "lastIndex"))
    global? = flag?(re_obj, "g") or flag?(re_obj, "y")
    from = if global?, do: last, else: 0

    if from > cp_count(subject) do
      if global?, do: strict_set(re_obj, "lastIndex", 0.0)
      :null
    else
      case match_at(re_obj, subject, from) do
        nil ->
          if global?, do: strict_set(re_obj, "lastIndex", 0.0)
          :null

        m ->
          if global?, do: strict_set(re_obj, "lastIndex", m.stop * 1.0)
          match_array(m, subject)
      end
    end
  end

  # RegExpExec: the object's own `exec` when it has one
  defp regexp_exec(rx, s) do
    case Interp.get(rx, "exec") do
      f when is_tuple(f) ->
        if function?(f) do
          r = call(f, rx, [s])

          unless r == :null or object?(r),
            do: throw_error("TypeError", "exec result must be an object or null")

          r
        else
          builtin_exec!(rx, s)
        end

      _ ->
        builtin_exec!(rx, s)
    end
  end

  defp builtin_exec!(rx, s) do
    unless regexp?(rx), do: throw_error("TypeError", "RegExp exec method called on a non-RegExp")
    exec(rx, s)
  end

  defp species_constructor(o, default) do
    c = Interp.get(o, "constructor")

    cond do
      c == :undefined ->
        default

      not object?(c) ->
        throw_error("TypeError", "constructor is not an object")

      true ->
        case Interp.get(c, @sym_species) do
          s when s in [:undefined, :null] ->
            default

          s ->
            if constructor?(s),
              do: s,
              else: throw_error("TypeError", "species is not a constructor")
        end
    end
  end

  defp ctor, do: :erlang.get(:regexp_ctor)

  defp group_text(result, i) do
    case Interp.get(result, Integer.to_string(i)) do
      :undefined -> :undefined
      v -> to_str(v)
    end
  end

  # the `@@match` loop of a global regexp and friends: advance past an empty match
  defp bump_empty(rx, matched) do
    if matched == "" do
      this_index = tolen(Interp.get(rx, "lastIndex"))
      strict_set(rx, "lastIndex", (this_index + 1) * 1.0)
    end
  end

  def symbol_match(this, string) do
    rx = require_object(this)
    s = to_str(string)
    flags = to_str(Interp.get(rx, "flags"))

    if not String.contains?(flags, "g") do
      regexp_exec(rx, s)
    else
      strict_set(rx, "lastIndex", 0.0)
      match_loop(rx, s, [])
    end
  end

  defp match_loop(rx, s, acc) do
    case regexp_exec(rx, s) do
      :null ->
        if acc == [], do: :null, else: new_array(Enum.reverse(acc))

      result ->
        matched = to_str(Interp.get(result, "0"))
        bump_empty(rx, matched)
        match_loop(rx, s, [matched | acc])
    end
  end

  def symbol_match_all(this, string) do
    r = require_object(this)
    s = to_str(string)
    c = species_constructor(r, ctor())
    flags = to_str(Interp.get(r, "flags"))
    matcher = construct(c, [r, flags])
    strict_set(matcher, "lastIndex", tolen(Interp.get(r, "lastIndex")) * 1.0)

    it = new_object([], proto(:regexp_string_iterator))
    {:obj, id} = it

    store(
      id,
      Map.put(deref(id), :re_iter, {matcher, s, String.contains?(flags, "g"), make_ref()})
    )

    it
  end

  defp string_iterator_next({:obj, id} = this) do
    case Map.get(deref(id), :re_iter) do
      {rx, s, global?, ref} ->
        if :erlang.get(ref) == :done do
          new_object([{"value", :undefined}, {"done", true}])
        else
          case regexp_exec(rx, s) do
            :null ->
              :erlang.put(ref, :done)
              new_object([{"value", :undefined}, {"done", true}])

            match ->
              if global? do
                bump_empty(rx, to_str(Interp.get(match, "0")))
              else
                :erlang.put(ref, :done)
              end

              new_object([{"value", match}, {"done", false}])
          end
        end

      _ ->
        _ = this
        throw_error("TypeError", "next called on an incompatible receiver")
    end
  end

  defp string_iterator_next(_), do: throw_error("TypeError", "next called on a non-object")

  def symbol_search(this, string) do
    rx = require_object(this)
    s = to_str(string)
    previous = Interp.get(rx, "lastIndex")
    unless same_value?(previous, 0.0), do: strict_set(rx, "lastIndex", 0.0)
    result = regexp_exec(rx, s)
    current = Interp.get(rx, "lastIndex")
    unless same_value?(current, previous), do: strict_set(rx, "lastIndex", previous)
    if result == :null, do: -1.0, else: Interp.get(result, "index")
  end

  def symbol_split(this, string, limit) do
    rx = require_object(this)
    s = to_str(string)
    c = species_constructor(rx, ctor())
    flags = to_str(Interp.get(rx, "flags"))
    new_flags = if String.contains?(flags, "y"), do: flags, else: flags <> "y"
    splitter = construct(c, [rx, new_flags])
    lim = if limit == :undefined, do: 4_294_967_295, else: to_uint32(limit)
    size = cp_count(s)

    cond do
      lim == 0 ->
        new_array([])

      size == 0 ->
        if regexp_exec(splitter, s) != :null, do: new_array([]), else: new_array([s])

      true ->
        split_loop(splitter, s, size, lim, 0, 0, [])
    end
  end

  defp to_uint32(v) do
    case to_num(v) do
      n when n in [:nan, :infinity, :neg_infinity] -> 0
      n -> Integer.mod(trunc(n), 4_294_967_296)
    end
  end

  defp split_loop(splitter, s, size, lim, p, q, acc) do
    if q >= size do
      new_array(Enum.reverse([Str.slice(s, p, size - p) | acc]))
    else
      strict_set(splitter, "lastIndex", q * 1.0)

      case regexp_exec(splitter, s) do
        :null ->
          split_loop(splitter, s, size, lim, p, q + 1, acc)

        z ->
          e = min(tolen(Interp.get(splitter, "lastIndex")), size)

          if e == p do
            split_loop(splitter, s, size, lim, p, q + 1, acc)
          else
            acc = [Str.slice(s, p, q - p) | acc]

            if length(acc) == lim do
              new_array(Enum.reverse(acc))
            else
              n = max(tolen(Interp.get(z, "length")) - 1, 0)

              case add_captures(z, 1, n, acc, lim) do
                {:full, acc} -> new_array(Enum.reverse(acc))
                {:ok, acc} -> split_loop(splitter, s, size, lim, e, e, acc)
              end
            end
          end
      end
    end
  end

  defp add_captures(_z, i, n, acc, _lim) when i > n, do: {:ok, acc}

  defp add_captures(z, i, n, acc, lim) do
    acc = [Interp.get(z, Integer.to_string(i)) | acc]
    if length(acc) == lim, do: {:full, acc}, else: add_captures(z, i + 1, n, acc, lim)
  end

  def symbol_replace(this, string, replace_value) do
    rx = require_object(this)
    s = to_str(string)
    len = cp_count(s)
    functional? = function?(replace_value)
    replace_value = if functional?, do: replace_value, else: to_str(replace_value)
    flags = to_str(Interp.get(rx, "flags"))
    global? = String.contains?(flags, "g")
    if global?, do: strict_set(rx, "lastIndex", 0.0)
    results = collect_results(rx, s, global?, [])

    {out, next} =
      Enum.reduce(results, {[], 0}, fn result, {acc, next_pos} ->
        n_captures = max(tolen(Interp.get(result, "length")) - 1, 0)
        matched = to_str(Interp.get(result, "0"))
        match_len = cp_count(matched)

        position =
          case Interp.get(result, "index") |> to_num() do
            n when n in [:nan] -> 0
            :infinity -> len
            :neg_infinity -> 0
            n -> trunc(n) |> max(0) |> min(len)
          end

        captures = for i <- 1..n_captures//1, do: group_text(result, i)
        named = Interp.get(result, "groups")

        replacement =
          if functional? do
            args = [matched | captures] ++ [position * 1.0, s]
            args = if named == :undefined, do: args, else: args ++ [named]
            to_str(call(replace_value, :undefined, args))
          else
            named = if named == :undefined, do: named, else: to_object(named)
            get_substitution(matched, s, position, captures, named, replace_value)
          end

        if position >= next_pos do
          {[replacement, Str.slice(s, next_pos, position - next_pos) | acc], position + match_len}
        else
          {acc, next_pos}
        end
      end)

    tail = if next >= len, do: "", else: Str.slice(s, next, len - next)
    IO.iodata_to_binary(Enum.reverse([tail | out]))
  end

  defp to_object({:obj, _} = o), do: o

  defp to_object(v) when v in [:undefined, :null],
    do: throw_error("TypeError", "Cannot convert undefined or null to object")

  defp to_object(v), do: v

  defp collect_results(rx, s, global?, acc) do
    case regexp_exec(rx, s) do
      :null ->
        Enum.reverse(acc)

      result ->
        if global? do
          bump_empty(rx, to_str(Interp.get(result, "0")))
          collect_results(rx, s, true, [result | acc])
        else
          Enum.reverse([result | acc])
        end
    end
  end

  @doc "GetSubstitution: expands `$&`, `$1`, `$<name>` and friends in a replacement template."
  def get_substitution(matched, str, position, captures, named, template),
    do: subst(template, matched, str, position, captures, named, [])

  defp subst("", _m, _s, _p, _c, _n, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp subst("$$" <> r, m, s, p, c, n, acc), do: subst(r, m, s, p, c, n, ["$" | acc])
  defp subst("$&" <> r, m, s, p, c, n, acc), do: subst(r, m, s, p, c, n, [m | acc])

  defp subst("$`" <> r, m, s, p, c, n, acc),
    do: subst(r, m, s, p, c, n, [Str.slice(s, 0, p) | acc])

  defp subst("$'" <> r, m, s, p, c, n, acc) do
    tail = p + cp_count(m)
    len = cp_count(s)
    subst(r, m, s, p, c, n, [if(tail >= len, do: "", else: Str.slice(s, tail, len - tail)) | acc])
  end

  defp subst("$<" <> r, m, s, p, c, n, acc) do
    case {n, String.split(r, ">", parts: 2)} do
      {:undefined, _} ->
        subst(r, m, s, p, c, n, ["$<" | acc])

      {_, [name, rest]} ->
        v =
          case Interp.get(n, name) do
            :undefined -> ""
            v -> to_str(v)
          end

        subst(rest, m, s, p, c, n, [v | acc])

      _ ->
        subst(r, m, s, p, c, n, ["$<" | acc])
    end
  end

  defp subst(<<"$0", d, rest::binary>>, m, s, p, c, n, acc) when d in ?1..?9 do
    if d - ?0 <= length(c) do
      case Enum.at(c, d - ?0 - 1) do
        :undefined -> subst(rest, m, s, p, c, n, acc)
        v -> subst(rest, m, s, p, c, n, [v | acc])
      end
    else
      subst(rest, m, s, p, c, n, [<<"$0", d>> | acc])
    end
  end

  defp subst(<<"$", d, rest::binary>>, m, s, p, c, n, acc) when d in ?1..?9 do
    count = length(c)

    {index, digits, rest} =
      case rest do
        <<d2, rest2::binary>> when d2 in ?0..?9 ->
          two = (d - ?0) * 10 + (d2 - ?0)

          if two >= 1 and two <= count,
            do: {two, <<d, d2>>, rest2},
            else: {d - ?0, <<d>>, rest}

        _ ->
          {d - ?0, <<d>>, rest}
      end

    if index >= 1 and index <= count do
      case Enum.at(c, index - 1) do
        :undefined -> subst(rest, m, s, p, c, n, acc)
        v -> subst(rest, m, s, p, c, n, [v | acc])
      end
    else
      subst(rest, m, s, p, c, n, ["$" <> digits | acc])
    end
  end

  defp subst(<<c::utf8, rest::binary>>, m, s, p, caps, n, acc),
    do: subst(rest, m, s, p, caps, n, [<<c::utf8>> | acc])

  # ── String.prototype methods that take a regexp ────────────

  defp coercible!(this, name) do
    if this in [:undefined, :null],
      do: throw_error("TypeError", "String.prototype.#{name} called on null or undefined")

    this
  end

  # `string.match(x)` and `string.search(x)`: the method of `x` if it has one
  defp via_symbol(this, x, sym, name, flags) do
    o = coercible!(this, name)

    method =
      if object?(x), do: get_method(x, sym)

    if method do
      call(method, x, [o])
    else
      s = to_str(o)
      rx = new(if(x == :undefined, do: "", else: to_str(x)), flags)
      call(Interp.get(rx, sym), rx, [s])
    end
  end

  def str_match(this, x), do: via_symbol(this, x, @sym_match, "match", "")
  def str_search(this, x), do: via_symbol(this, x, @sym_search, "search", "")

  def str_match_all(this, x) do
    o = coercible!(this, "matchAll")

    if object?(x) do
      if is_regexp(x) do
        flags = Interp.get(x, "flags")

        if flags in [:undefined, :null],
          do: throw_error("TypeError", "flags is null or undefined")

        unless String.contains?(to_str(flags), "g"),
          do:
            throw_error(
              "TypeError",
              "String.prototype.matchAll called with a non-global RegExp argument"
            )
      end
    end

    via_symbol(o, x, @sym_match_all, "matchAll", "g")
  end

  def str_replace(this, search, replace_value, all?) do
    o = coercible!(this, if(all?, do: "replaceAll", else: "replace"))

    if search not in [:undefined, :null] and all? and is_regexp(search) do
      flags = Interp.get(search, "flags")

      if flags in [:undefined, :null], do: throw_error("TypeError", "flags is null or undefined")

      unless String.contains?(to_str(flags), "g"),
        do: throw_error("TypeError", "replaceAll must be called with a global RegExp")
    end

    replacer = if object?(search), do: get_method(search, @sym_replace)

    if replacer do
      call(replacer, search, [o, replace_value])
    else
      s = to_str(o)
      pattern = to_str(search)
      functional? = function?(replace_value)
      replace_value = if functional?, do: replace_value, else: to_str(replace_value)
      plen = cp_count(pattern)

      positions =
        if all? do
          find_all(s, pattern, plen, 0, cp_count(s), [])
        else
          case find_from(s, pattern, 0) do
            nil -> []
            i -> [i]
          end
        end

      {out, last} =
        Enum.reduce(positions, {[], 0}, fn pos, {acc, from} ->
          replacement =
            if functional?,
              do: to_str(call(replace_value, :undefined, [pattern, pos * 1.0, s])),
              else: get_substitution(pattern, s, pos, [], :undefined, replace_value)

          {[replacement, Str.slice(s, from, pos - from) | acc], pos + plen}
        end)

      IO.iodata_to_binary(Enum.reverse([Str.slice(s, last, cp_count(s) - last) | out]))
    end
  end

  # the code point index of `pattern` in `s` at or after `from`
  defp find_from(s, pattern, from) do
    fb = byte_of(s, from)

    if fb > byte_size(s) or from > cp_count(s) do
      nil
    else
      if pattern == "" do
        from
      else
        case :binary.match(s, pattern, scope: {fb, byte_size(s) - fb}) do
          :nomatch -> nil
          {b, _} -> cp_count(binary_part(s, 0, b))
        end
      end
    end
  end

  defp find_all(s, pattern, plen, from, len, acc) do
    if from > len do
      Enum.reverse(acc)
    else
      case find_from(s, pattern, from) do
        nil -> Enum.reverse(acc)
        i -> find_all(s, pattern, plen, i + max(1, plen), len, [i | acc])
      end
    end
  end

  def str_split(this, sep, limit) do
    o = coercible!(this, "split")
    splitter = if object?(sep), do: get_method(sep, @sym_split)

    if splitter do
      call(splitter, sep, [o, limit])
    else
      s = to_str(o)
      lim = if limit == :undefined, do: 4_294_967_295, else: to_uint32(limit)
      r = to_str(sep)

      parts =
        cond do
          lim == 0 -> []
          sep == :undefined -> [s]
          s == "" -> if r == "", do: [], else: [s]
          r == "" -> String.codepoints(s)
          true -> :binary.split(s, r, [:global])
        end

      new_array(Enum.take(parts, lim))
    end
  end

  # ── install ────────────────────────────────────────────────

  def install(scope) do
    p = new_object()
    put_proto(:regexp, p)

    ctor =
      native("RegExp", fn this, args ->
        pattern = arg(args, 0)
        flags = arg(args, 1)
        plain_call? = not object?(this)
        pattern_is_regexp = is_regexp(pattern)

        if plain_call? and pattern_is_regexp and flags == :undefined and
             Interp.get(pattern, "constructor") == ctor() do
          pattern
        else
          {pat, fl} =
            cond do
              regexp?(pattern) ->
                {source_of(pattern), if(flags == :undefined, do: flags_of(pattern), else: flags)}

              pattern_is_regexp ->
                {Interp.get(pattern, "source"),
                 if(flags == :undefined, do: Interp.get(pattern, "flags"), else: flags)}

              true ->
                {pattern, flags}
            end

          new(
            if(pat == :undefined, do: "", else: to_str(pat)),
            if(fl == :undefined, do: "", else: to_str(fl))
          )
        end
      end)

    :erlang.put(:regexp_ctor, ctor)

    put_const(ctor, "prototype", p)
    put_hidden(p, "constructor", ctor)
    declare(scope, "RegExp", ctor)
    def_species(ctor)

    # `source`, `flags` and the flag accessors live on the prototype
    for {name, flag} <- [
          {"hasIndices", "d"},
          {"global", "g"},
          {"ignoreCase", "i"},
          {"multiline", "m"},
          {"dotAll", "s"},
          {"unicode", "u"},
          {"unicodeSets", "v"},
          {"sticky", "y"}
        ] do
      Props.define_accessor(p, name,
        get:
          native("get " <> name, fn this, _ ->
            cond do
              regexp?(this) ->
                flag?(this, flag)

              this == p ->
                :undefined

              true ->
                throw_error("TypeError", "RegExp.prototype.#{name} getter called on a non-RegExp")
            end
          end),
        enumerable: false
      )
    end

    Props.define_accessor(p, "source",
      get:
        native("get source", fn this, _ ->
          cond do
            regexp?(this) ->
              escape_source(source_of(this))

            this == p ->
              "(?:)"

            true ->
              throw_error("TypeError", "RegExp.prototype.source getter called on a non-RegExp")
          end
        end),
      enumerable: false
    )

    Props.define_accessor(p, "flags",
      get:
        native("get flags", fn this, _ ->
          unless match?({:obj, _}, this),
            do: throw_error("TypeError", "RegExp.prototype.flags getter called on a non-object")

          for {name, ch} <- [
                {"hasIndices", "d"},
                {"global", "g"},
                {"ignoreCase", "i"},
                {"multiline", "m"},
                {"dotAll", "s"},
                {"unicode", "u"},
                {"unicodeSets", "v"},
                {"sticky", "y"}
              ],
              truthy(Interp.get(this, name)),
              into: "",
              do: ch
        end),
      enumerable: false
    )

    # RegExp.escape(string): the string as a pattern that matches it literally
    put_hidden(
      ctor,
      "escape",
      native("escape", fn _, args ->
        case arg(args, 0) do
          str when is_binary(str) -> escape_pattern(str)
          _ -> throw_error("TypeError", "RegExp.escape requires a string")
        end
      end)
      |> then(fn {:obj, id} = f ->
        store(id, Map.put(deref(id), :arity, 1.0))
        f
      end)
    )

    def_fn1 = fn name, fun ->
      f = native(name, fun)
      {:obj, fid} = f
      store(fid, Map.put(deref(fid), :arity, 1.0))
      put_hidden(p, name, f)
    end

    def_fn1.("test", fn this, args ->
      rx = require_object(this)
      regexp_exec(rx, to_str(arg(args, 0))) != :null
    end)

    def_fn1.("exec", fn this, args ->
      unless regexp?(this),
        do: throw_error("TypeError", "RegExp.prototype.exec called on a non-RegExp")

      exec(this, to_str(arg(args, 0)))
    end)

    def_fn(p, "toString", fn this, _ ->
      rx = require_object(this)
      "/" <> to_str(Interp.get(rx, "source")) <> "/" <> to_str(Interp.get(rx, "flags"))
    end)

    def_sym = fn sym, name, arity, fun ->
      f = native(name, fun)
      {:obj, fid} = f
      store(fid, Map.put(deref(fid), :arity, arity * 1.0))
      put_hidden(p, sym, f)
    end

    def_sym.(@sym_match, "[Symbol.match]", 1, fn this, args ->
      symbol_match(this, arg(args, 0))
    end)

    def_sym.(@sym_match_all, "[Symbol.matchAll]", 1, fn this, args ->
      symbol_match_all(this, arg(args, 0))
    end)

    def_sym.(@sym_replace, "[Symbol.replace]", 2, fn this, args ->
      symbol_replace(this, arg(args, 0), arg(args, 1))
    end)

    def_sym.(@sym_search, "[Symbol.search]", 1, fn this, args ->
      symbol_search(this, arg(args, 0))
    end)

    def_sym.(@sym_split, "[Symbol.split]", 2, fn this, args ->
      symbol_split(this, arg(args, 0), arg(args, 1))
    end)

    # %RegExpStringIteratorPrototype%
    ip = new_object([], Interp.proto(:iterator))
    put_proto(:regexp_string_iterator, ip)
    def_fn(ip, "next", fn this, _ -> string_iterator_next(this) end)
    put_tag(ip, "RegExp String Iterator")

    :ok
  end

  @syntax_chars ~c"^$\\.*+?()[]{}|/"
  @other_punct ~c",-=<>#&!%:;@~'`\""
  @escape_space [
                  0x09,
                  0x0B,
                  0x0C,
                  0x20,
                  0xA0,
                  0xFEFF,
                  0x1680,
                  0x202F,
                  0x205F,
                  0x3000,
                  0x0A,
                  0x0D,
                  0x2028,
                  0x2029
                ] ++
                  Enum.to_list(0x2000..0x200A)

  defp escape_pattern(<<c::utf8, rest::binary>>) do
    first =
      if c in ?0..?9 or c in ?a..?z or c in ?A..?Z, do: hex_escape(c), else: escape_char(c)

    first <> escape_rest(rest)
  end

  defp escape_pattern(""), do: ""

  defp escape_rest(<<c::utf8, rest::binary>>), do: escape_char(c) <> escape_rest(rest)
  defp escape_rest(""), do: ""

  defp escape_char(c) when c in @syntax_chars, do: <<?\\, c>>
  defp escape_char(?\t), do: "\\t"
  defp escape_char(?\n), do: "\\n"
  defp escape_char(0x0B), do: "\\v"
  defp escape_char(?\f), do: "\\f"
  defp escape_char(?\r), do: "\\r"

  defp escape_char(c) when c in @other_punct or c in @escape_space do
    if c <= 0xFF,
      do: hex_escape(c),
      else:
        "\\u" <> (c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0"))
  end

  defp escape_char(c), do: <<c::utf8>>

  defp hex_escape(c),
    do: "\\x" <> (c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0"))

  defp def_fn(obj, name, fun), do: put_hidden(obj, name, native(name, fun))
end
