defmodule Browser.JS.Test262Test do
  use ExUnit.Case, async: true
  alias Browser.JS.Test262

  @header """
  // Copyright (C) 2020 someone. All rights reserved.
  /*---
  esid: sec-example
  description: |
    a longer description
    over two lines
  info: >
    folded
  includes: [compareArray.js, propertyHelper.js]
  flags: [onlyStrict, async]
  features:
    - Symbol
    - class
  negative:
    phase: parse
    type: SyntaxError
  ---*/
  var x = 1;
  """

  describe "parse_meta/1" do
    test "scalars, lists, block lists and maps" do
      meta = Test262.parse_meta(@header)
      assert meta["esid"] == "sec-example"
      assert meta["includes"] == ["compareArray.js", "propertyHelper.js"]
      assert meta["flags"] == ["onlyStrict", "async"]
      assert meta["features"] == ["Symbol", "class"]
      assert meta["negative"] == %{"phase" => "parse", "type" => "SyntaxError"}
      assert meta["description"] == ""
    end

    test "no header" do
      assert Test262.parse_meta("var x;") == %{}
    end
  end

  describe "decide/3" do
    test "skips what the runtime cannot do" do
      assert Test262.decide(%{"features" => ["generators"]}, "") == {:skip, "feature generators"}
      assert Test262.decide(%{"flags" => ["module"]}, "") == {:skip, "module"}
      assert {:skip, _} = Test262.decide(%{}, "$262.createRealm()")
      assert Test262.decide(%{"features" => ["arrow-function"]}, "") == :run
      assert Test262.decide(%{"features" => ["generators"]}, "", skip_features: []) == :run
    end
  end

  describe "run_test/4" do
    # a tiny stand-in for the real harness
    defp harness do
      Test262.load_harness(
        harness_dir(),
        ["assert.js", "sta.js", "doneprintHandle.js"]
      )
    end

    defp harness_dir do
      dir = Path.join(System.tmp_dir!(), "t262-harness-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "harness"))

      File.write!(Path.join([dir, "harness", "assert.js"]), """
      function Test262Error(message) { this.message = message || ""; }
      Test262Error.prototype.toString = function () { return "Test262Error: " + this.message; };
      var assert = function (mustBeTrue, message) { if (mustBeTrue !== true) throw new Test262Error(message || "assertion failed"); };
      assert.sameValue = function (actual, expected, message) { if (actual !== expected) throw new Test262Error(message || "Expected " + expected + " but got " + actual); };
      assert.throws = function (expectedErrorConstructor, func, message) {
        try { func(); } catch (thrown) { if (thrown.constructor !== expectedErrorConstructor) throw new Test262Error(message || "wrong error"); return; }
        throw new Test262Error(message || "no exception");
      };
      """)

      File.write!(
        Path.join([dir, "harness", "sta.js"]),
        "function $DONOTEVALUATE() { throw 'Test262: This statement should not be evaluated.'; }"
      )

      File.write!(Path.join([dir, "harness", "doneprintHandle.js"]), """
      function $DONE(error) {
        if (error) { print('Test262:AsyncTestFailure:' + (error.message || error)); }
        else { print('Test262:AsyncTestComplete'); }
      }
      """)

      dir
    end

    defp run(source, meta \\ nil) do
      meta = meta || Test262.parse_meta(source)
      Test262.run_test(source, meta, harness())
    end

    test "a test that does not throw passes, one that throws fails with its message" do
      assert run("/*---\ndescription: x\n---*/\nassert.sameValue(1 + 1, 2);") == :pass

      assert {:fail, "Test262Error: Expected 3 but got 2"} =
               run("/*---\n---*/\nassert.sameValue(1 + 1, 3);")
    end

    test "negative tests" do
      src = "/*---\nnegative:\n  phase: runtime\n  type: TypeError\n---*/\nnull.x;"
      assert run(src) == :pass
      wrong = "/*---\nnegative:\n  phase: runtime\n  type: RangeError\n---*/\nnull.x;"
      assert {:fail, "expected RangeError" <> _} = run(wrong)
      fine = "/*---\nnegative:\n  phase: runtime\n  type: TypeError\n---*/\n1;"
      assert {:fail, "expected TypeError, but it ran fine"} = run(fine)

      parse =
        "/*---\nnegative:\n  phase: parse\n  type: SyntaxError\n---*/\n$DONOTEVALUATE();\nvar = ;"

      assert run(parse) == :pass
    end

    test "async tests pass when $DONE() is called, later or not" do
      ok =
        "/*---\nflags: [async]\n---*/\nPromise.resolve(1).then(function (v) { assert.sameValue(v, 1); }).then($DONE, $DONE);"

      assert run(ok) == :pass

      failing =
        "/*---\nflags: [async]\n---*/\nPromise.resolve(1).then(function (v) { assert.sameValue(v, 2); }).then($DONE, $DONE);"

      assert {:fail, "Test262:AsyncTestFailure:Expected 2 but got 1"} = run(failing)

      never = "/*---\nflags: [async]\n---*/\nvar x = 1;"
      assert {:fail, "$DONE was never called"} = run(never)
    end

    test "raw tests run without the harness, and a loop is stopped" do
      assert run("/*---\nflags: [raw]\n---*/\nvar ok = 1;") == :pass

      assert {:fail, "step limit"} =
               Test262.run_test("/*---\n---*/\nwhile (true) {}", %{}, harness(), max_steps: 1000)
    end
  end

  test "collect/2 finds tests and leaves out fixtures" do
    root = Path.join(System.tmp_dir!(), "t262-collect-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([root, "test", "a", "b"]))

    for f <- ["a/x.js", "a/b/y.js", "a/b/z_FIXTURE.js", "a/notes.txt"],
        do: File.write!(Path.join([root, "test", f]), "")

    assert Test262.collect(root, ["a"]) == ["a/b/y.js", "a/x.js"]
    assert Test262.collect(root, ["a/x.js"]) == ["a/x.js"]
    assert Test262.collect(root, ["nope"]) == []
  end
end
