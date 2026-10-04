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
    opts =
      [:unicode, :dollar_endonly] ++
        for(
          {f, o} <- [{"i", :caseless}, {"m", :multiline}, {"s", :dotall}],
          String.contains?(flags, f),
          do: o
        )

    case :re.compile(translate(source), opts) do
      {:ok, re} ->
        {:namelist, names} = :re.inspect(re, :namelist)
        {:ok, {re, names}}

      {:error, {msg, _}} ->
        {:error, msg}
    end
  end

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
        groups =
          for {s, l} <- caps do
            if s < 0, do: :undefined, else: binary_part(subject, s, l)
          end

        named = named_groups(names, groups)

        %{
          start: cp_count(binary_part(subject, 0, start)),
          stop: cp_count(binary_part(subject, 0, start + len)),
          text: binary_part(subject, start, len),
          groups: groups,
          named: named
        }

      _ ->
        nil
    end
  end

  # the :namelist order is the order of the names in the pattern, which is the group order
  # for the named groups; their indices are found from the name list of the compiled pattern
  defp named_groups([], _), do: nil

  defp named_groups(names, groups),
    do: names |> Enum.zip(named_values(names, groups)) |> Map.new(fn {n, v} -> {n, v} end)

  # (best effort: the groups of a pattern with named groups are mostly all named)
  defp named_values(names, groups), do: Enum.take(groups, length(names))

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
    put(arr, "index", m.start * 1.0)
    put(arr, "input", subject)

    groups =
      case m.named do
        nil -> :undefined
        named -> new_object(Enum.map(named, fn {k, v} -> {k, v} end))
      end

    put(arr, "groups", groups)
    arr
  end

  defp put(o, k, v), do: Interp.put(o, k, v)

  @doc "`re.exec(subject)`: the match array or null, advancing `lastIndex` for g/y regexps."
  def exec(re_obj, subject) do
    global? = flag?(re_obj, "g") or flag?(re_obj, "y")
    from = if global?, do: to_int(Interp.get(re_obj, "lastIndex")), else: 0

    if from > 0 and from > cp_count(subject) do
      put(re_obj, "lastIndex", 0.0)
      :null
    else
      case match_at(re_obj, subject, from) do
        nil ->
          if global?, do: put(re_obj, "lastIndex", 0.0)
          :null

        m ->
          if global?, do: put(re_obj, "lastIndex", m.stop * 1.0)
          match_array(m, subject)
      end
    end
  end

  @doc "All matches of `re_obj` in `subject`, as match records."
  def all_matches(re_obj, subject), do: all_matches(re_obj, subject, 0, [])

  defp all_matches(re_obj, subject, from, acc) do
    if from > cp_count(subject) do
      Enum.reverse(acc)
    else
      case match_at(re_obj, subject, from) do
        nil ->
          Enum.reverse(acc)

        m ->
          # an empty match steps on by one so the scan always ends
          next = if m.stop == m.start, do: m.stop + 1, else: m.stop
          all_matches(re_obj, subject, next, [m | acc])
      end
    end
  end

  # ── String methods ─────────────────────────────────────────

  def string_match(s, re_obj) do
    if flag?(re_obj, "g") do
      case all_matches(re_obj, s) do
        [] -> :null
        ms -> new_array(Enum.map(ms, & &1.text))
      end
    else
      put_hidden(re_obj, "lastIndex", 0.0)
      exec(re_obj, s)
    end
  end

  def string_match_all(s, re_obj) do
    unless flag?(re_obj, "g"),
      do:
        throw_error(
          "TypeError",
          "String.prototype.matchAll called with a non-global RegExp argument"
        )

    new_array(Enum.map(all_matches(re_obj, s), &match_array(&1, s)))
  end

  def string_search(s, re_obj) do
    case match_at(re_obj, s, 0) do
      nil -> -1.0
      m -> m.start * 1.0
    end
  end

  def string_split(s, re_obj, limit) do
    matches =
      all_matches(re_obj, s)
      |> Enum.reject(&(&1.stop == &1.start and &1.start >= cp_count(s)))

    {parts, last} =
      Enum.reduce(matches, {[], 0}, fn m, {acc, from} ->
        if m.stop == m.start and m.start == from and from == 0 do
          {acc, from}
        else
          piece = Str.slice(s, from, m.start - from)
          caps = for g <- m.groups, do: g
          {Enum.reverse(caps) ++ [piece | acc], m.stop}
        end
      end)

    parts = Enum.reverse([Str.slice(s, last, cp_count(s)) | parts])
    parts = if limit == :undefined, do: parts, else: Enum.take(parts, to_int(limit))
    new_array(parts)
  end

  @doc "`s.replace(re, repl)` and `s.replaceAll(re, repl)`."
  def string_replace(s, re_obj, repl, all?) do
    if all? and not flag?(re_obj, "g"),
      do: throw_error("TypeError", "replaceAll must be called with a global RegExp")

    matches =
      if flag?(re_obj, "g"),
        do: all_matches(re_obj, s),
        else: List.wrap(match_at(re_obj, s, 0))

    {out, last} =
      Enum.reduce(matches, {[], 0}, fn m, {acc, from} ->
        piece = Str.slice(s, from, m.start - from)
        {[expand(repl, m, s), piece | acc], m.stop}
      end)

    IO.iodata_to_binary(Enum.reverse([Str.slice(s, last, cp_count(s)) | out]))
  end

  defp expand(repl, m, s) do
    if function?(repl) do
      extra = if m.named, do: [new_object(Enum.map(m.named, fn {k, v} -> {k, v} end))], else: []
      args = [m.text | m.groups] ++ [m.start * 1.0, s] ++ extra
      to_str(call(repl, :undefined, args))
    else
      substitute(to_str(repl), m, s)
    end
  end

  defp substitute(template, m, s), do: substitute(template, m, s, [])

  defp substitute("", _m, _s, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp substitute("$$" <> r, m, s, acc), do: substitute(r, m, s, ["$" | acc])
  defp substitute("$&" <> r, m, s, acc), do: substitute(r, m, s, [m.text | acc])

  defp substitute("$`" <> r, m, s, acc),
    do: substitute(r, m, s, [Str.slice(s, 0, m.start) | acc])

  defp substitute("$'" <> r, m, s, acc),
    do: substitute(r, m, s, [Str.slice(s, m.stop, cp_count(s)) | acc])

  defp substitute("$<" <> r, m, s, acc) do
    case String.split(r, ">", parts: 2) do
      [name, rest] ->
        v = if m.named, do: Map.get(m.named, name, :undefined), else: :undefined
        substitute(rest, m, s, [if(v == :undefined, do: "", else: v) | acc])

      _ ->
        substitute(r, m, s, ["$<" | acc])
    end
  end

  defp substitute(<<"$", d, rest::binary>>, m, s, acc) when d in ?1..?9 do
    # two digits when such a group exists
    {n, rest} =
      case rest do
        <<d2, rest2::binary>>
        when d2 in ?0..?9 and (d - ?0) * 10 + (d2 - ?0) <= length(m.groups) ->
          {(d - ?0) * 10 + (d2 - ?0), rest2}

        _ ->
          {d - ?0, rest}
      end

    case Enum.at(m.groups, n - 1) do
      nil -> substitute(rest, m, s, ["$#{n}" | acc])
      :undefined -> substitute(rest, m, s, acc)
      g -> substitute(rest, m, s, [g | acc])
    end
  end

  defp substitute(<<c::utf8, rest::binary>>, m, s, acc),
    do: substitute(rest, m, s, [<<c::utf8>> | acc])

  # ── install ────────────────────────────────────────────────

  def install(scope) do
    p = new_object()
    put_proto(:regexp, p)

    ctor =
      native("RegExp", fn _this, args ->
        case arg(args, 0) do
          {:obj, _} = r when is_tuple(r) ->
            if regexp?(r) do
              flags =
                if arg(args, 1) == :undefined,
                  do: flags_of(r),
                  else: to_str(arg(args, 1))

              new(source_of(r), flags)
            else
              new(to_str(r), flags_arg(args))
            end

          :undefined ->
            new("(?:)", flags_arg(args))

          v ->
            new(to_str(v), flags_arg(args))
        end
      end)

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

    def_fn(p, "test", fn this, args -> exec(this, to_str(arg(args, 0))) != :null end)
    def_fn(p, "exec", fn this, args -> exec(this, to_str(arg(args, 0))) end)

    def_fn(p, "toString", fn this, _ ->
      "/" <> Interp.get(this, "source") <> "/" <> Interp.get(this, "flags")
    end)

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

  defp flags_arg(args), do: if(arg(args, 1) == :undefined, do: "", else: to_str(arg(args, 1)))
  defp def_fn(obj, name, fun), do: put_hidden(obj, name, native(name, fun))
end
