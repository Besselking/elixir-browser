defmodule Browser.JS.KeysTest do
  # The key conversion of the data-model step (D1). `Interp.index/1` has clauses that skip
  # the parse of a string that cannot be an index and that compare a float only with floats.
  # This oracle compares it with the function that it replaced, which is copied here.
  use ExUnit.Case, async: true

  alias Browser.JS.Interp

  # The old `index/1`, before the data-model step.
  defp old_index(k) when is_number(k) and k >= 0 and k < 4_294_967_295 and k == trunc(k),
    do: trunc(k)

  defp old_index(k) when is_binary(k) do
    case Integer.parse(k) do
      {i, ""} when i >= 0 and i < 4_294_967_295 -> if Integer.to_string(i) == k, do: i
      _ -> nil
    end
  end

  defp old_index(_), do: nil

  @fixed [
    -0.0,
    0.0,
    1.0,
    1.5,
    -1.0,
    9.0,
    10.0,
    4_294_967_294.0,
    4_294_967_294.5,
    4_294_967_295.0,
    4_294_967_296.0,
    1.0e21,
    -1.0e21,
    5.0e-324,
    0,
    1,
    -1,
    4_294_967_294,
    4_294_967_295,
    "0",
    "1",
    "9",
    "10",
    "01",
    "00",
    "+1",
    " 1",
    "1 ",
    "-0",
    "-1",
    "1.0",
    "1e3",
    "0x1",
    "4294967294",
    "4294967295",
    "4294967296",
    "99999999999999999999",
    "push",
    "length",
    "",
    "1_000",
    :nan,
    :infinity,
    :neg_infinity,
    :undefined,
    {:symbol, :iterator, "Symbol.iterator"},
    {:private, 1}
  ]

  test "index/1 gives the old results for the fixed keys" do
    for k <- @fixed, do: assert({k, Interp.index(k)} == {k, old_index(k)})
  end

  test "index/1 gives the old results for 100000 random keys" do
    :rand.seed(:exsss, {1, 2, 3})

    for _ <- 1..100_000 do
      k = random_key()
      assert {k, Interp.index(k)} == {k, old_index(k)}
    end
  end

  # A random key: an integer or a float near the bounds of an index, or a string made of
  # digits and a few other characters, with and without a sign.
  defp random_key do
    case :rand.uniform(6) do
      1 ->
        :rand.uniform(5_000_000_000) - 100

      2 ->
        (:rand.uniform(5_000_000_000) - 100) * 1.0

      3 ->
        :rand.uniform() * 5_000_000_000.0

      4 ->
        Integer.to_string(:rand.uniform(5_000_000_000) - 100)

      5 ->
        Enum.map_join(1..:rand.uniform(12), fn _ -> Enum.random(~w(0 1 2 9 0 0 - + . e x a)) end)

      6 ->
        4_294_967_290 + :rand.uniform(10) + Enum.random([0, 0.0, 0.5])
    end
  end
end
