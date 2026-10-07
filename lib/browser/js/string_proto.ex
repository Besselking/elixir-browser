defmodule Browser.JS.StringProto do
  @moduledoc """
  The `String.prototype` methods whose argument handling the specification pins down:
  `includes`, `startsWith`, `endsWith`, `indexOf`, `lastIndexOf`, `repeat`, the index methods,
  case conversion (with the final sigma rule), `normalize`, `localeCompare` and the well-formed
  helpers. Strings are measured in UTF-16 code units (see `Browser.JS.Str`).
  """

  import Browser.JS.Interp, except: [get: 2, put: 3]
  alias Browser.JS.{RegExp, Str}

  defp arg(args, i), do: Enum.at(args, i, :undefined)

  def install(p) do
    str_fn(p, "includes", 1, fn s, args ->
      needle = search_string(arg(args, 0), "includes")
      from = args |> arg(1) |> to_int() |> clamp(Str.length(s))
      Str.index_of(s, needle, from) >= 0
    end)

    str_fn(p, "startsWith", 1, fn s, args ->
      needle = search_string(arg(args, 0), "startsWith")
      from = args |> arg(1) |> to_int() |> clamp(Str.length(s))

      from + Str.length(needle) <= Str.length(s) and
        Str.slice(s, from, Str.length(needle)) == needle
    end)

    str_fn(p, "endsWith", 1, fn s, args ->
      needle = search_string(arg(args, 0), "endsWith")
      len = Str.length(s)

      stop =
        case arg(args, 1) do
          :undefined -> len
          v -> v |> to_int() |> clamp(len)
        end

      start = stop - Str.length(needle)
      start >= 0 and Str.slice(s, start, Str.length(needle)) == needle
    end)

    str_fn(p, "indexOf", 1, fn s, args ->
      needle = to_str(arg(args, 0))
      from = args |> arg(1) |> to_int() |> clamp(Str.length(s))
      float(Str.index_of(s, needle, from))
    end)

    str_fn(p, "lastIndexOf", 1, fn s, args ->
      needle = to_str(arg(args, 0))

      from =
        case to_num(arg(args, 1)) do
          :nan -> Str.length(s)
          :infinity -> Str.length(s)
          :neg_infinity -> 0
          n -> n |> trunc() |> clamp(Str.length(s))
        end

      float(last_index_of(s, needle, from))
    end)

    str_fn(p, "repeat", 1, fn s, args ->
      n =
        case to_num(arg(args, 0)) do
          :nan -> 0
          x when x in [:infinity, :neg_infinity] -> -1
          x -> trunc(x)
        end

      cond do
        n < 0 -> throw_error("RangeError", "Invalid count value")
        n == 0 or s == "" -> ""
        n * byte_size(s) > 536_870_912 -> throw_error("RangeError", "Invalid string length")
        true -> String.duplicate(s, n)
      end
    end)

    str_fn(p, "charAt", 1, fn s, args ->
      case to_int(arg(args, 0)) do
        i when i < 0 -> ""
        i -> Str.at(s, i) || ""
      end
    end)

    str_fn(p, "charCodeAt", 1, fn s, args ->
      case Str.code_unit_at(s, to_int(arg(args, 0))) do
        nil -> :nan
        c -> float(c)
      end
    end)

    str_fn(p, "codePointAt", 1, fn s, args ->
      case code_point_at(s, to_int(arg(args, 0))) do
        nil -> :undefined
        c -> float(c)
      end
    end)

    str_fn(p, "toLowerCase", 0, fn s, _ -> lower(s) end)
    str_fn(p, "toLocaleLowerCase", 0, fn s, _ -> lower(s) end)
    str_fn(p, "toUpperCase", 0, fn s, _ -> String.upcase(s) end)
    str_fn(p, "toLocaleUpperCase", 0, fn s, _ -> String.upcase(s) end)
    str_fn(p, "isWellFormed", 0, fn s, _ -> not Str.lone?(s) end)
    str_fn(p, "toWellFormed", 0, fn s, _ -> Str.well_formed(s) end)

    str_fn(p, "normalize", 0, fn s, args ->
      form =
        case arg(args, 0) do
          :undefined -> "NFC"
          f -> to_str(f)
        end

      normalize(s, form)
    end)

    str_fn(p, "localeCompare", 1, fn s, args ->
      other = args |> arg(0) |> to_str() |> normalize("NFC")
      s = normalize(s, "NFC")

      cond do
        s < other -> -1.0
        s > other -> 1.0
        true -> 0.0
      end
    end)

    :ok
  end

  # RequireObjectCoercible and ToString of `this` happen before the arguments are read
  defp str_fn(obj, name, arity, fun) do
    f =
      native(name, fn this, args ->
        if nullish?(this),
          do: throw_error("TypeError", "String.prototype.#{name} called on null or undefined"),
          else: fun.(to_str(this), args)
      end)

    set_arity(f, arity)
    put_hidden(obj, name, f)
  end

  defp search_string(v, name) do
    if RegExp.is_regexp(v),
      do:
        throw_error(
          "TypeError",
          "First argument to String.prototype.#{name} must not be a regular expression"
        )

    to_str(v)
  end

  defp float(n), do: n * 1.0

  defp clamp(n, len), do: n |> max(0) |> min(len)

  defp code_point_at(s, i), do: Str.code_point_at(s, i)

  # the largest index <= `from` at which `needle` occurs, or -1
  defp last_index_of(s, needle, from) do
    us = s |> Str.units() |> List.to_tuple()
    want = Str.units(needle)
    n = length(want)
    top = min(from, tuple_size(us) - n)

    Enum.find(top..0//-1, -1, fn i -> matches_at?(us, i, want) end)
  end

  defp matches_at?(_us, _i, []), do: true

  defp matches_at?(us, i, [c | rest]),
    do: elem(us, i) == c and matches_at?(us, i + 1, rest)

  defp normalize(s, "NFC"), do: :unicode.characters_to_nfc_binary(s)
  defp normalize(s, "NFD"), do: :unicode.characters_to_nfd_binary(s)
  defp normalize(s, "NFKC"), do: :unicode.characters_to_nfkc_binary(s)
  defp normalize(s, "NFKD"), do: :unicode.characters_to_nfkd_binary(s)

  defp normalize(_, form),
    do:
      throw_error(
        "RangeError",
        "The normalization form should be one of NFC, NFD, NFKC, NFKD: #{form}"
      )

  # toLowerCase with the Final_Sigma special casing: Σ becomes ς at the end of a word
  defp lower(s) do
    if String.contains?(s, "Σ") do
      cps = String.codepoints(s)

      cps
      |> Enum.with_index()
      |> Enum.map(fn
        {"Σ", i} -> if final_sigma?(cps, i), do: "ς", else: "σ"
        {c, _} -> String.downcase(c)
      end)
      |> Enum.join()
    else
      String.downcase(s)
    end
  end

  defp final_sigma?(cps, i) do
    before = cps |> Enum.take(i) |> Enum.reverse()
    after_ = Enum.drop(cps, i + 1)
    cased_before?(before) and not cased_before?(after_)
  end

  # the first character that is not case-ignorable is cased
  defp cased_before?(cps) do
    case Enum.find(cps, &(not case_ignorable?(&1))) do
      nil -> false
      c -> Regex.match?(~r/^[\p{Lu}\p{Ll}\p{Lt}]$/u, c)
    end
  end

  defp case_ignorable?(c),
    do:
      c in ["'", ".", ":", "·", "’", "­"] or
        Regex.match?(~r/^[\p{Mn}\p{Me}\p{Cf}\p{Lm}\p{Sk}]$/u, c)
end
