defmodule Browser.JSJsonTest do
  use ExUnit.Case, async: true

  alias Browser.JS.{Builtins, Interp, Json}

  # A string that JSON.parse gives must not point into the JSON text: the text can be large and
  # the script can keep the string for a long time.
  test "a long string from JSON.parse does not keep the JSON text" do
    Interp.init(1_000_000)
    Builtins.install()
    long = String.duplicate("abcdefghij", 10)
    text = ~s({"k":"#{long}","pad":"#{String.duplicate("z", 100_000)}"})
    v = Interp.get(Json.parse(text, :undefined), "k")
    assert v == long
    assert :binary.referenced_byte_size(v) == byte_size(long)
  end
end
