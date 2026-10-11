# Usage: elixir bench/ab.exs DIR_A DIR_B [options] [-- program ...]
#
# Compares two builds of the browser with interleaved runs. DIR_A and DIR_B are two
# checkouts of the repository, for example two worktrees:
#
#     git worktree add /tmp/ab_a main
#     elixir bench/ab.exs /tmp/ab_a . --rounds 3
#
# The script compiles both checkouts. Then it runs `bench/js_runtime.exs` in A, then in B,
# and it does this ROUNDS times. The runs alternate, so a change in the load of the machine
# touches both builds in the same way. For each program the table shows the minimum time and
# the minimum Mred of all rounds, and the change from A to B in percent. Under the table are
# the sums of the nine programs and of the groups of step 2d, steps 2e and 4, and step 3.
# Both builds run the same copy of the bench script (the copy in this checkout, or
# `--script`), so that both print the same programs in the same format.
#
# Options:
#
#   * `--rounds N` - the number of rounds (default 3)
#   * `--level L` - the resolver level, `RESOLVE` of the bench script (default 4)
#   * `--runs N` - `RUNS` of the bench script (default 5)
#   * `--env-a K=V`, `--env-b K=V` - an environment variable for one build only (for
#     example `--env-a JS_COMPILE=0`); the option can be given more than once
#   * `--speedometer SUITE` - run `bench/speedometer.exs` with `LAYOUT=1` for one suite
#     instead, and compare the `MRED` lines and the scores. The mirror must be served at
#     `--url` (default http://localhost:8765/Speedometer3.1/)
#   * `--script PATH` - the bench script to run
#   * `--out DIR` - keep the output of each run in DIR
#
# The arguments after `--` go to the bench script (names or parts of names of programs).

{opts, rest, _} =
  OptionParser.parse(System.argv(),
    return_separator: true,
    strict: [
      rounds: :integer,
      level: :string,
      runs: :integer,
      env_a: :keep,
      env_b: :keep,
      speedometer: :string,
      url: :string,
      script: :string,
      out: :string
    ]
  )

{dirs, programs} =
  case Enum.split_while(rest, &(&1 != "--")) do
    {dirs, ["--" | programs]} -> {dirs, programs}
    {dirs, []} -> {dirs, []}
  end

[dir_a, dir_b] =
  case Enum.map(dirs, &Path.expand/1) do
    [_, _] = two -> two
    _ -> raise "give two checkouts: elixir bench/ab.exs DIR_A DIR_B [options]"
  end

here = Path.expand("..", __DIR__)
rounds = opts[:rounds] || 3
level = opts[:level] || "4"
suite = opts[:speedometer]
url = opts[:url] || "http://localhost:8765/Speedometer3.1/"
out = opts[:out]
if out, do: File.mkdir_p!(out)

script =
  Path.expand(
    opts[:script] ||
      Path.join(here, if(suite, do: "bench/speedometer.exs", else: "bench/js_runtime.exs"))
  )

side_env = fn key ->
  for kv <- Keyword.get_values(opts, key) do
    [k, v] = String.split(kv, "=", parts: 2)
    {k, v}
  end
end

builds = [{"A", dir_a, side_env.(:env_a)}, {"B", dir_b, side_env.(:env_b)}]

# Each build compiles once before the first round, with its own environment: a variable such
# as `JS_RESOLVE_CHECK` can change what the build contains.
for {name, dir, env} <- builds do
  {text, status} = System.cmd("mix", ["compile"], cd: dir, env: env, stderr_to_stdout: true)
  if status != 0, do: raise("mix compile failed in #{name} (#{dir}):\n#{text}")
end

run_once = fn {name, dir, env}, round ->
  {args, env} =
    if suite do
      {[script, url, suite, "240"], [{"LAYOUT", "1"}, {"RESOLVE", level} | env]}
    else
      {[script | programs], [{"RUNS", to_string(opts[:runs] || 5)}, {"RESOLVE", level} | env]}
    end

  {text, status} =
    System.cmd("mix", ["run", "--no-start" | args], cd: dir, env: env, stderr_to_stdout: true)

  if out, do: File.write!(Path.join(out, "#{name}_#{round}.txt"), text)
  if status != 0, do: IO.puts("warning: build #{name}, round #{round} exited with #{status}")
  text
end

# The rows of one output of `bench/js_runtime.exs`: {group, program, ms, Mred}. A header line
# of the script starts a new group.
parse_runtime = fn text ->
  text
  |> String.split("\n")
  |> Enum.reduce({"nine", []}, fn line, {group, rows} ->
    cond do
      String.starts_with?(line, "step 2d") ->
        {"2d", rows}

      String.starts_with?(line, "step 2e") ->
        {"2e+4", rows}

      String.starts_with?(line, "step 3") ->
        {"3", rows}

      m = Regex.run(~r/^(.{34})\s*(\d+\.\d+)\s+(\d+\.\d+)\s/, line) ->
        [_, name, ms, mred] = m
        name = String.trim(name)

        if name in ["program", "total"],
          do: {group, rows},
          else: {group, [{group, name, String.to_float(ms), String.to_float(mred)} | rows]}

      true ->
        {group, rows}
    end
  end)
  |> elem(1)
  |> Enum.reverse()
end

# The `MRED` line and the score of one output of `bench/speedometer.exs`.
parse_speedometer = fn text ->
  mred =
    case Regex.run(~r/MRED whole ([\d.]+) run ([\d.]+) ms (\d+) cpu (\d+)/, text) do
      [_, w, r, ms, cpu] ->
        [
          {"x", "whole-VM Mred", String.to_float(w), nil},
          {"x", "run-phase Mred", String.to_float(r), nil},
          {"x", "run ms", String.to_integer(ms) * 1.0, nil},
          {"x", "cpu ms", String.to_integer(cpu) * 1.0, nil}
        ]

      nil ->
        []
    end

  score =
    case Regex.run(~r/score: "'?([\d.]+)/, text) do
      [_, s] -> [{"x", "score (max)", -String.to_float(s), nil}]
      nil -> []
    end

  mred ++ score
end

parse = if suite, do: parse_speedometer, else: parse_runtime

# The runs alternate A, B, A, B, ... so that the load of the machine touches both builds.
# The table keeps the order of the rows of the first output of A.
{results, order} =
  for round <- 1..rounds, {name, _, _} = build <- builds, reduce: {%{}, nil} do
    {acc, order} ->
      IO.write(:stderr, "round #{round}, build #{name}\n")
      rows = parse.(run_once.(build, round))
      order = order || Enum.map(rows, &elem(&1, 1))

      acc =
        Enum.reduce(rows, acc, fn {group, prog, a, b}, acc ->
          Map.update(acc, {name, prog}, {group, a, b}, fn {g, a0, b0} ->
            {g, min(a, a0), if(b == nil, do: nil, else: min(b, b0))}
          end)
        end)

      {acc, order}
  end

pct = fn a, b ->
  if a == 0 do
    "     -"
  else
    d = 100 * (b - a) / a
    sign = if d < 0, do: "-", else: "+"
    String.pad_leading(sign <> :erlang.float_to_binary(abs(d), decimals: 1) <> "%", 7)
  end
end

num = fn x, d -> String.pad_leading(:erlang.float_to_binary(abs(x) * 1.0, decimals: d), 10) end
order = order || []

IO.puts(
  String.pad_trailing(if(suite, do: "#{suite} (#{rounds} rounds)", else: "program"), 36) <>
    if(suite,
      do: "         A         B   change",
      else: "    A ms    B ms  change     A Mred    B Mred  change"
    )
)

sums =
  for prog <- order, Map.has_key?(results, {"B", prog}), reduce: %{} do
    sums ->
      {group, a_ms, a_red} = results[{"A", prog}]
      {_, b_ms, b_red} = results[{"B", prog}]

      if suite do
        IO.puts(
          String.pad_trailing(prog, 36) <>
            num.(a_ms, 3) <> num.(b_ms, 3) <> " " <> to_string(pct.(abs(a_ms), abs(b_ms)))
        )

        sums
      else
        IO.puts(
          String.pad_trailing(prog, 36) <>
            String.pad_leading(:erlang.float_to_binary(a_ms, decimals: 1), 8) <>
            String.pad_leading(:erlang.float_to_binary(b_ms, decimals: 1), 8) <>
            " " <>
            to_string(pct.(a_ms, b_ms)) <>
            num.(a_red, 3) <> num.(b_red, 3) <> " " <> to_string(pct.(a_red, b_red))
        )

        Map.update(sums, group, {a_ms, b_ms, a_red, b_red}, fn {w, x, y, z} ->
          {w + a_ms, x + b_ms, y + a_red, z + b_red}
        end)
      end
  end

for group <- ["nine", "2d", "2e+4", "3"], Map.has_key?(sums, group) do
  {a_ms, b_ms, a_red, b_red} = sums[group]

  IO.puts(
    String.pad_trailing("sum of #{group}", 36) <>
      String.pad_leading(:erlang.float_to_binary(a_ms, decimals: 1), 8) <>
      String.pad_leading(:erlang.float_to_binary(b_ms, decimals: 1), 8) <>
      " " <>
      to_string(pct.(a_ms, b_ms)) <>
      num.(a_red, 3) <> num.(b_red, 3) <> " " <> to_string(pct.(a_red, b_red))
  )
end
