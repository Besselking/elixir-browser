defmodule Mix.Tasks.Wasm.Spec do
  @shortdoc "Runs the WebAssembly spec tests (wast2json output) against Browser.Wasm"
  @moduledoc """
  Runs the WebAssembly spec tests against `Browser.Wasm`.

      mix wasm.spec DIR [names...] [--verbose]

  `DIR` holds the output of `wast2json` (a `NAME.json` per test file with the `.wasm` files it
  names). With names, only those files run. Prints one line per file with the counts of passed
  and failed commands, and the failures with `--verbose`.
  """
  use Mix.Task

  alias Browser.Wasm
  alias Browser.Wasm.{Error, Func, Global, Memory, Num, Table}

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [verbose: :boolean])
    [dir | names] = rest
    Mix.Task.run("compile")

    files =
      case names do
        [] -> dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()
        _ -> Enum.map(names, &Path.join(dir, &1 <> ".json"))
      end

    results =
      for file <- files do
        task = Task.async(fn -> run_file(file, dir) end)

        {pass, fail, skip, failures} =
          case Task.yield(task, 300_000) || Task.shutdown(task, :brutal_kill) do
            {:ok, r} -> r
            _ -> {0, 1, 0, ["timeout"]}
          end

        IO.puts(
          "#{String.pad_trailing(Path.basename(file, ".json"), 28)} pass #{pass} fail #{fail} skip #{skip}"
        )

        if opts[:verbose], do: Enum.each(Enum.take(failures, 15), &IO.puts("    " <> &1))
        {pass, fail, skip}
      end

    {p, f, s} =
      Enum.reduce(results, {0, 0, 0}, fn {a, b, c}, {x, y, z} -> {a + x, b + y, c + z} end)

    IO.puts("total pass #{p} fail #{f} skip #{s}")
  end

  defp run_file(file, dir) do
    cmds = file |> File.read!() |> JSON.decode!() |> Map.fetch!("commands")

    st = %{dir: dir, mods: %{}, last: nil, registry: %{}, pass: 0, fail: 0, skip: 0, failures: []}
    st = Enum.reduce(cmds, st, &command/2)
    {st.pass, st.fail, st.skip, Enum.reverse(st.failures)}
  end

  defp ok(st), do: %{st | pass: st.pass + 1}
  defp skip(st), do: %{st | skip: st.skip + 1}

  defp bad(st, cmd, why),
    do: %{
      st
      | fail: st.fail + 1,
        failures: ["line #{cmd["line"]} #{cmd["type"]}: #{why}" | st.failures]
    }

  defp command(%{"type" => "module"} = cmd, st) do
    bin = File.read!(Path.join(st.dir, cmd["filename"]))

    try do
      mod = Wasm.compile(bin)
      inst = Wasm.instantiate(mod, resolver(st))
      st = %{st | mods: Map.put(st.mods, :last, inst), last: inst}
      st = if cmd["name"], do: %{st | mods: Map.put(st.mods, cmd["name"], inst)}, else: st
      ok(st)
    rescue
      e in Error -> bad(%{st | last: nil}, cmd, "module: #{e.kind} #{e.message}")
    end
  end

  defp command(%{"type" => "register"} = cmd, st) do
    inst = lookup(st, cmd["name"])
    if inst, do: ok(%{st | registry: Map.put(st.registry, cmd["as"], inst)}), else: skip(st)
  end

  defp command(%{"type" => "action"} = cmd, st) do
    case perform(st, cmd["action"]) do
      {:ok, _} -> ok(st)
      :skip -> skip(st)
      {:error, e} -> bad(st, cmd, inspect(e))
    end
  end

  defp command(%{"type" => "assert_return"} = cmd, st) do
    case perform(st, cmd["action"]) do
      {:ok, vals} ->
        expected = cmd["expected"]

        if length(vals) == length(expected) and
             Enum.all?(Enum.zip(vals, expected), fn {v, e} -> match_value(v, e) end),
           do: ok(st),
           else:
             bad(
               st,
               cmd,
               "got #{inspect(vals)} want #{inspect(expected)} #{inspect(cmd["action"]["args"])}"
             )

      :skip ->
        skip(st)

      {:error, e} ->
        bad(st, cmd, inspect(e))
    end
  end

  defp command(%{"type" => t} = cmd, st) when t in ["assert_trap", "assert_exhaustion"] do
    case perform(st, cmd["action"]) do
      {:error, %Error{kind: :trap, message: m}} ->
        if String.starts_with?(m, cmd["text"] || ""),
          do: ok(st),
          else: bad(st, cmd, "trap #{m}, want #{cmd["text"]}")

      {:error, e} ->
        bad(st, cmd, "wrong error #{inspect(e)}")

      :skip ->
        skip(st)

      {:ok, v} ->
        bad(st, cmd, "no trap, got #{inspect(v)}")
    end
  end

  defp command(%{"type" => t, "module_type" => "binary"} = cmd, st)
       when t in ["assert_invalid", "assert_malformed"] do
    bin = File.read!(Path.join(st.dir, cmd["filename"]))

    try do
      Wasm.compile(bin)
      bad(st, cmd, "accepted: want #{cmd["text"]}")
    rescue
      e in Error ->
        if e.kind == :compile, do: ok(st), else: bad(st, cmd, "wrong kind #{e.kind}")
    end
  end

  defp command(%{"type" => t}, st) when t in ["assert_invalid", "assert_malformed"], do: skip(st)

  defp command(%{"type" => t} = cmd, st)
       when t in ["assert_unlinkable", "assert_uninstantiable"] do
    want = if t == "assert_unlinkable", do: :link, else: :trap

    if String.ends_with?(cmd["filename"], ".wat") do
      skip(st)
    else
      bin = File.read!(Path.join(st.dir, cmd["filename"]))

      try do
        Wasm.compile(bin) |> Wasm.instantiate(resolver(st))
        bad(st, cmd, "instantiated: want #{cmd["text"]}")
      rescue
        e in Error ->
          if e.kind == want, do: ok(st), else: bad(st, cmd, "wrong #{e.kind} #{e.message}")
      end
    end
  end

  defp command(_, st), do: skip(st)

  defp export(inst, name), do: Enum.find(inst.exports, fn {n, _, _} -> n == name end)

  defp lookup(st, nil), do: st.last
  defp lookup(st, name), do: Map.get(st.mods, name)

  defp perform(st, %{"type" => "invoke"} = a) do
    with %{} = inst <- lookup(st, a["module"]),
         {_, :func, f} <- export(inst, a["field"]) do
      try do
        {:ok, Wasm.invoke(f, Enum.map(a["args"], &value/1))}
      rescue
        e in Error -> {:error, e}
      end
    else
      _ -> :skip
    end
  end

  defp perform(st, %{"type" => "get"} = a) do
    with %{} = inst <- lookup(st, a["module"]),
         {_, :global, g} <- export(inst, a["field"]) do
      {:ok, [Global.get(g)]}
    else
      _ -> :skip
    end
  end

  defp value(%{"type" => "i32", "value" => v}), do: String.to_integer(v)
  defp value(%{"type" => "i64", "value" => v}), do: String.to_integer(v)
  defp value(%{"type" => "f32", "value" => v}), do: Num.f32_from_bits(String.to_integer(v))
  defp value(%{"type" => "f64", "value" => v}), do: Num.f64_from_bits(String.to_integer(v))

  defp value(%{"type" => "v128", "lane_type" => lt, "value" => vs}),
    do: vs |> Enum.map(&String.to_integer/1) |> Browser.Wasm.Simd.pack(lane_bits(lt))

  defp value(%{"type" => "externref", "value" => "null"}), do: :null
  defp value(%{"type" => "externref", "value" => v}), do: {:extern, String.to_integer(v)}
  defp value(%{"type" => "funcref", "value" => "null"}), do: :null

  defp match_value(v, %{"type" => "v128", "lane_type" => lt, "value" => es}) do
    b = lane_bits(lt)
    ft = if lt in ["f32", "f64"], do: lt

    is_integer(v) and
      Enum.all?(Enum.zip(Browser.Wasm.Simd.lanes(v, b), es), fn {x, e} ->
        case e do
          "nan:canonical" -> x in canonical(ft)
          "nan:arithmetic" -> arithmetic_nan?(ft, x)
          _ -> x == String.to_integer(e)
        end
      end)
  end

  defp match_value(v, %{"type" => t, "value" => "nan:canonical"}) do
    case v do
      {:nan, bits} -> bits in canonical(t)
      _ -> false
    end
  end

  defp match_value(v, %{"value" => "nan:arithmetic"}), do: match?({:nan, _}, v)
  defp match_value(v, %{"type" => "i32", "value" => e}), do: v == String.to_integer(e)
  defp match_value(v, %{"type" => "i64", "value" => e}), do: v == String.to_integer(e)

  defp match_value(v, %{"type" => "f32", "value" => e}),
    do: Num.f32_to_bits(v) == String.to_integer(e)

  defp match_value(v, %{"type" => "f64", "value" => e}),
    do: Num.f64_to_bits(v) == String.to_integer(e)

  defp match_value(v, %{"type" => "externref", "value" => "null"}), do: v == :null

  defp match_value(v, %{"type" => "externref", "value" => e}),
    do: v == {:extern, String.to_integer(e)}

  defp match_value(v, %{"type" => "funcref", "value" => "null"}), do: v == :null
  defp match_value(v, %{"type" => "funcref"}), do: match?(%Func{}, v)
  defp match_value(v, %{"type" => "externref"}), do: v != :null

  defp lane_bits(lt), do: lt |> String.slice(1..-1//1) |> String.to_integer()

  defp arithmetic_nan?("f32", x), do: Num.f32_from_bits(x) |> then(&match?({:nan, _}, &1))
  defp arithmetic_nan?("f64", x), do: Num.f64_from_bits(x) |> then(&match?({:nan, _}, &1))

  defp canonical("f32"), do: [0x7FC00000, 0xFFC00000]
  defp canonical("f64"), do: [0x7FF8000000000000, 0xFFF8000000000000]

  defp resolver(st) do
    fn mod, name, desc ->
      case mod do
        "spectest" ->
          spectest(name, desc)

        _ ->
          with %{} = inst <- Map.get(st.registry, mod),
               {_, _, v} <- export(inst, name) do
            v
          else
            _ -> nil
          end
      end
    end
  end

  defp spectest("global_i32", _), do: spec_global(:i32, 666)
  defp spectest("global_i64", _), do: spec_global(:i64, 666)
  defp spectest("global_f32", _), do: spec_global(:f32, Num.round32(666.6))
  defp spectest("global_f64", _), do: spec_global(:f64, 666.6)
  defp spectest("table", _), do: Table.new(:funcref, 10, 20)
  defp spectest("table64", _), do: Table.new(:funcref, 10, 20, :null, :i64)
  defp spectest("memory", _), do: Memory.new(1, 2)
  defp spectest("shared_memory", _), do: Memory.new(1, 2, true)

  defp spectest("print" <> _, {:func, type}), do: Func.host(type, fn _ -> [] end)

  defp spectest(_, _), do: nil

  defp spec_global(t, v), do: Global.new(t, false, v)
end
