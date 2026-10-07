defmodule Browser.CalcTest do
  use ExUnit.Case, async: true

  alias Browser.Calc

  defp units("px"), do: 1.0
  defp units("rem"), do: 16.0
  defp units("em"), do: 10.0
  defp units(_), do: nil

  defp ev(text), do: Calc.eval(text, &units/1)

  test "math?/1" do
    assert Calc.math?("calc(1px + 2px)")
    assert Calc.math?("min(1px, 2px)")
    assert Calc.math?("CALC(1px)")
    refute Calc.math?("10px")
    refute Calc.math?("calcium")
  end

  test "plain arithmetic" do
    assert ev("calc(1px + 2px)") == {:ok, {:px, 3.0}}
    assert ev("calc(10px - 4px)") == {:ok, {:px, 6.0}}
    assert ev("calc(2px * 3)") == {:ok, {:px, 6.0}}
    assert ev("calc(3 * 2px)") == {:ok, {:px, 6.0}}
    assert ev("calc(12px / 4)") == {:ok, {:px, 3.0}}
  end

  test "minified, as Tailwind writes it" do
    assert ev("calc(.25rem*6)") == {:ok, {:px, 24.0}}
    assert ev("calc(.25rem*-4)") == {:ok, {:px, -16.0}}
    assert ev("calc(1.75/1.25)") == {:ok, {:num, 1.4}}
  end

  test "precedence and parentheses" do
    assert ev("calc(1px + 2px * 3)") == {:ok, {:px, 7.0}}
    assert ev("calc((1px + 2px) * 3)") == {:ok, {:px, 9.0}}
    assert ev("calc(10px - 2px - 3px)") == {:ok, {:px, 5.0}}
  end

  test "units" do
    assert ev("calc(1rem + 2em)") == {:ok, {:px, 36.0}}
    assert ev("calc(1fortnight)") == :error
  end

  test "percentages stay percentages" do
    assert {:ok, {:pct, f}} = ev("calc(100% / 3)")
    assert_in_delta f, 1 / 3, 1.0e-9
    assert ev("calc(50% + 25%)") == {:ok, {:pct, 0.75}}
  end

  test "mixing percentages and lengths waits for the size the percentage is of" do
    assert ev("calc(100% - 2rem)") == {:ok, {:calc, -32.0, 1.0}}
    assert ev("calc((50% - 10px) * 2)") == {:ok, {:calc, -20.0, 1.0}}
    assert ev("min(50%, 10px)") == :error
  end

  test "min, max, clamp" do
    assert ev("min(3px, 1px, 2px)") == {:ok, {:px, 1.0}}
    assert ev("max(1rem, 10px)") == {:ok, {:px, 16.0}}
    assert ev("clamp(10px, 5px, 20px)") == {:ok, {:px, 10.0}}
    assert ev("clamp(10px, 50px, 20px)") == {:ok, {:px, 20.0}}
    assert ev("clamp(10px, 15px, 20px)") == {:ok, {:px, 15.0}}
    assert ev("min(100%, 600px)") == :error
  end

  test "nested" do
    assert ev("calc(max(1px, 2px) + min(5px, 3px))") == {:ok, {:px, 5.0}}
    assert ev("calc(calc(1px + 1px) * 2)") == {:ok, {:px, 4.0}}
  end

  test "bad input" do
    assert ev("calc(1px +)") == :error
    assert ev("calc(1px 2px)") == :error
    assert ev("calc(1px / 0)") == :error
    assert ev("calc(1px * 2px)") == :error
    assert ev("calc(1px") == :error
    assert ev("calc()") == :error
  end
end
