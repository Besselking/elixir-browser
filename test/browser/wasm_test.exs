defmodule Browser.WasmTest do
  use ExUnit.Case, async: true

  alias Browser.Wasm
  alias Browser.Wasm.{Error, Func, Global, Memory, Num, Table}

  # These modules were made from WAT text with wabt and are kept as base64.
  @fib "AGFzbQEAAAABBgFgAX8BfwMCAQAHBwEDZmliAAAKHgEcACAAQQJJBH8gAAUgAEEBaxAAIABBAmsQAGoLCw=="
  @mem "AGFzbQEAAAABDwNgAX8Bf2ACf38AYAABfwMGBQABAAACBQQBAQECBzAGA21lbQIABWxvYWQ4AAAHc3RvcmUzMgABBmxvYWQzMgACBGdyb3cAAwRzaXplAAQKJwUHACAALQAACwkAIAAgATYCAAsHACAAKAIACwYAIABAAAsEAD8ACwsLAQBBCAsFaGVsbG8="
  @tbl "AGFzbQEAAAABDAJgAX8Bf2ACf38BfwMEAwAAAQQEAXAAAwcOAgN0YmwBAARjYWxsAAIJCAEAQQALAgABChsDBwAgAEECbAsHACAAQQNsCwkAIAEgABEAAAs="
  @imp "AGFzbQEAAAABDAJgAn9/AX9gAX8BfwIUAgNlbnYDYWRkAAADZW52AWcDfwEDAgEBBgYBfwFBAAsHDQIDY250AwEDcnVuAAEKFQETACAAIwAQACQAIwFBAWokASMACw=="
  @ctl "AGFzbQEAAAABIgZgAX8Bf2ACf38Bf2AAAGACf38Cf39gAn19AX1gAn5+AX4DCAcAAAECAwQFBy0HAnN3AAADc3VtAAEDZGl2AAIEdHJhcAADBHN3YXAABAFmAAUGaTY0bXVsAAYKYQcaAAJAAkACQCAADgIAAQILQQoPC0EUDwtBHgshAQF/AkADQCAARQ0BIAEgAGohASAAQQFrIQAMAAsLIAELBwAgACABbQsDAAALBgAgASAACwcAIAAgAZILBwAgACABfgs="

  @tail "AGFzbQEAAAABBwFgAn9/AX8DAwIAAAQFAXABAQEHGAIJY291bnRkb3duAAAIdmlhVGFibGUAAQkHAQBBAAsBAAolAhcAIABFBH8gAQUgAEEBayABQQJqEgALCwsAIAAgAUEAEwAACw=="
  @multi "AGFzbQEAAAABEgRgAABgAX8Bf2ACf38AYAABfwMGBQABAQIDBQUCAAEAAQcpBQRjb3B5AAAFbG9hZEEAAQVsb2FkQgACBnN0b3JlQgADBXNpemVCAAQKLwUMAEEKQQBBAvwKAQALBwAgAC0AAAsIACAALUABAAsKACAAIAE6QAEACwQAPwELCwgBAEEACwJBQg=="

  defp inst(b64, resolve \\ fn _, _, _ -> nil end) do
    b64 |> Base.decode64!() |> Wasm.compile() |> Wasm.instantiate(resolve)
  end

  defp export(inst, name),
    do: Enum.find_value(inst.exports, fn {n, _, v} -> if n == name, do: v end)

  defp call(inst, name, args), do: Wasm.invoke(export(inst, name), args)

  test "recursion" do
    i = inst(@fib)
    assert call(i, "fib", [20]) == [6765]
  end

  test "memory, data segments, grow" do
    i = inst(@mem)
    assert call(i, "load8", [8]) == [?h]
    call(i, "store32", [100, 0xDEADBEEF])
    assert call(i, "load32", [100]) == [0xDEADBEEF]
    assert call(i, "load8", [100]) == [0xEF]
    assert call(i, "size", []) == [1]
    assert call(i, "grow", [1]) == [1]
    assert call(i, "grow", [1]) == [0xFFFFFFFF]
    assert Memory.size(export(i, "mem")) == 2
    # a store that crosses a page boundary
    call(i, "store32", [65534, 0x01020304])
    assert call(i, "load32", [65534]) == [0x01020304]

    assert %Error{kind: :trap, message: "out of bounds memory access"} =
             catch_error(call(i, "load32", [131_070]))
  end

  test "tables and call_indirect" do
    i = inst(@tbl)
    assert call(i, "call", [0, 21]) == [42]
    assert call(i, "call", [1, 21]) == [63]
    assert %Error{message: "uninitialized element"} = catch_error(call(i, "call", [2, 1]))
    assert %Error{message: "undefined element"} = catch_error(call(i, "call", [3, 1]))
    assert Table.size(export(i, "tbl")) == 3
  end

  test "imports and globals" do
    g = Global.new(:i32, true, 5)

    add =
      Func.host({[:i32, :i32], [:i32]}, fn [a, b] -> [Bitwise.band(a + b, 0xFFFFFFFF)] end)

    resolve = fn
      "env", "add", {:func, {[:i32, :i32], [:i32]}} -> add
      "env", "g", _ -> g
      _, _, _ -> nil
    end

    i = inst(@imp, resolve)
    assert call(i, "run", [10]) == [15]
    assert call(i, "run", [10]) == [25]
    assert Global.get(g) == 25
    assert Global.get(export(i, "cnt")) == 2

    assert %Error{kind: :link} = catch_error(inst(@imp, fn _, _, _ -> nil end))

    wrong = Global.new(:i64, true, 0)

    assert %Error{kind: :link} =
             catch_error(
               inst(@imp, fn
                 "env", "g", _ -> wrong
                 "env", "add", _ -> add
               end)
             )
  end

  test "control flow, traps, multi-value, floats, i64" do
    i = inst(@ctl)
    assert call(i, "sw", [0]) == [10]
    assert call(i, "sw", [1]) == [20]
    assert call(i, "sw", [2]) == [30]
    assert call(i, "sw", [99]) == [30]
    assert call(i, "sum", [100]) == [5050]
    assert call(i, "div", [7, 2]) == [3]
    assert call(i, "div", [Bitwise.band(-7, 0xFFFFFFFF), 2]) == [Bitwise.band(-3, 0xFFFFFFFF)]
    assert %Error{message: "integer divide by zero"} = catch_error(call(i, "div", [1, 0]))

    assert %Error{message: "integer overflow"} =
             catch_error(call(i, "div", [0x80000000, 0xFFFFFFFF]))

    assert %Error{kind: :trap, message: "unreachable"} = catch_error(call(i, "trap", []))
    assert call(i, "swap", [1, 2]) == [2, 1]
    assert call(i, "f", [1.5, 2.25]) == [3.75]
    assert call(i, "f", [3.4028234663852886e38, 3.4028234663852886e38]) == [:infinity]
    assert {:nan, _} = hd(call(i, "f", [:infinity, :neg_infinity]))
    assert call(i, "i64mul", [0xFFFFFFFFFFFFFFFF, 2]) == [0xFFFFFFFFFFFFFFFE]
  end

  test "tail calls do not grow the stack" do
    i = inst(@tail)
    assert call(i, "countdown", [1_000_000, 0]) == [2_000_000]
    assert call(i, "viaTable", [50_000, 1]) == [100_001]
  end

  test "several memories" do
    i = inst(@multi)
    assert call(i, "loadA", [1]) == [?B]
    assert call(i, "loadB", [10]) == [0]
    call(i, "copy", [])
    assert call(i, "loadB", [10]) == [?A]
    assert call(i, "loadB", [11]) == [?B]
    call(i, "storeB", [0, 9])
    assert call(i, "loadA", [0]) == [?A]
    assert call(i, "sizeB", []) == [1]
  end

  test "malformed and invalid modules" do
    assert %Error{kind: :compile, message: "magic header not detected"} =
             catch_error(Wasm.compile("nope"))

    assert %Error{kind: :compile} = catch_error(Wasm.compile(<<0, "asm", 2, 0, 0, 0>>))
    # a function that returns i32 but has an empty body
    bad = <<0, "asm", 1, 0, 0, 0, 1, 5, 1, 0x60, 0, 1, 0x7F, 3, 2, 1, 0, 10, 4, 1, 2, 0, 0x0B>>
    assert %Error{kind: :compile, message: "type mismatch"} = catch_error(Wasm.compile(bad))
    refute Wasm.valid?(bad)
    assert Wasm.valid?(<<0, "asm", 1, 0, 0, 0>>)
  end

  test "float helpers keep NaN payloads and signs" do
    assert Num.f32_to_bits(Num.f32_from_bits(0x7FA00000)) == 0x7FA00000
    assert Num.f64_to_bits(-0.0) == 0x8000000000000000
    assert Num.binop(:f64_min, 0.0, -0.0) |> Num.f64_to_bits() == 0x8000000000000000
    assert Num.unop(:f32_nearest, 2.5) == 2.0
    assert Num.unop(:f64_trunc, -0.5) |> Num.f64_to_bits() == 0x8000000000000000
    assert Num.unop(:i32_trunc_sat_f64_s, 1.0e20) == 0x7FFFFFFF
    assert Num.unop(:f32_convert_i64_u, 0xFFFFFFFFFFFFFFFF) == 1.8446744073709552e19
  end
end
