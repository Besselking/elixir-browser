defmodule Browser.JSRegExpFastTest do
  use ExUnit.Case, async: true

  alias Browser.JS

  # A RegExp with nothing changed takes the fast paths of `Browser.JS.RegExp` (`@@replace`,
  # `@@match`, `test`, `exec` and the `flags` read). A RegExp with an own `exec` key that holds
  # the built-in `exec` takes the protocol path, but it must give the same results. The tests
  # below compare the two paths.

  defp js(src, opts \\ []) do
    {:ok, value, _console} = JS.eval(src, opts)
    value
  end

  describe "the fast paths agree with the protocol" do
    @atoms [
      "a",
      "b",
      ".",
      "\\d",
      "\\s",
      "\\b",
      "^",
      "$",
      "a*",
      "b?",
      "x*",
      "[ab]",
      "(a)",
      "(b)?",
      "(?:ab)+",
      "(?=b)",
      "|",
      "é",
      "😀",
      "\\u{1F600}",
      "(?<n>a)",
      "\\$",
      "a+?",
      "(c|)",
      "(.)",
      "(😀)",
      "(?:)",
      "\\1"
    ]
    @chars ["a", "b", "c", " ", "\\n", "é", "😀", "$", "ab", "\\ud800", "\\udc00", "x"]
    @flags ["", "g", "gi", "gu", "y", "gy", "gm", "d", "gd", "u", "gv"]
    @templates ["-", "[$&]", "$1", "<$2|$1>", "$10", "$01", "$`", "$'", "$$", "$<n>", "$", ""]
    @last_index ["0", "0", "1", "3", "100", "'1'"]

    @ops [
      {"rs", "s.replace(re, TPL)"},
      {"rf", "s.replace(re, function () { return JSON.stringify([].slice.call(arguments)); })"},
      {"ra", "s.replaceAll(re, '<$&>')"},
      {"m", "s.match(re)"},
      {"t", "[T(re, s), re.lastIndex, T(re, s), re.lastIndex, T(re, s)]"},
      {"e", "[seen(re.exec(s)), re.lastIndex, seen(re.exec(s))]"},
      {"sp", "s.split(re)"},
      {"ma", "Array.from(s.matchAll(re), seen)"}
    ]

    defp pick(list), do: Enum.at(list, :rand.uniform(length(list)) - 1)

    defp random_case do
      pattern = Enum.map_join(1..:rand.uniform(4), fn _ -> pick(@atoms) end)
      subject = Enum.map_join(0..:rand.uniform(10), fn _ -> pick(@chars) end)
      {pattern, pick(@flags), subject, pick(@templates), pick(@last_index)}
    end

    # The results of `ops` on the case, and `lastIndex` after each. `slow?` gives the RegExp an
    # own `exec`, and `test` becomes a call of `exec`.
    defp run_case({pattern, flags, subject, template, last}, ops, slow?) do
      runs =
        for {name, body} <- ops do
          body = String.replace(body, "TPL", inspect(template))
          "run(#{inspect(name)}, function () { return #{body}; });"
        end

      src = """
      (function () {
        var re;
        try { re = new RegExp(#{inspect(pattern)}, "#{flags}"); } catch (e) { return "bad"; }
        if (#{slow?}) Object.defineProperty(re, "exec", { value: RegExp.prototype.exec });
        var T = #{slow?} ? function (r, s) { return r.exec(s) !== null; }
                         : function (r, s) { return r.test(s); };
        var s = "#{subject}", out = [];
        function seen(m) { return m && [m.slice(), m.index, m.groups, m.indices && m.indices.slice()]; }
        function run(name, f) {
          re.lastIndex = #{last};
          try { out.push(name, f(), re.lastIndex); } catch (e) { out.push(name, "throw " + e.name); }
        }
        #{Enum.join(runs, "\n")}
        return JSON.stringify(out);
      })()
      """

      case JS.eval(src, resolve: 4, max_steps: 20_000, timeout: 10_000) do
        {:ok, value, _} -> value
        {:error, reason, _} -> {:error, reason}
      end
    end

    # (an empty match before a character outside the BMP, without the `u` flag, makes a loop
    # that does not end on the two paths; then each operation runs alone)
    defp both_paths(c) do
      for slow? <- [false, true] do
        case run_case(c, @ops, slow?) do
          {:error, _} -> Enum.map(@ops, &run_case(c, [&1], slow?))
          value -> value
        end
      end
    end

    test "on random patterns, subjects and templates" do
      :rand.seed(:exsss, {20, 26, 10})

      for _ <- 1..150 do
        c = random_case()
        [fast, slow] = both_paths(c)
        assert fast == slow, "case #{inspect(c)}"
      end
    end
  end

  describe "the cases that take the protocol path" do
    test "replace with the g flag leaves lastIndex at 0; without it, lastIndex stays" do
      assert js("var r = /a/g; r.lastIndex = 2; ['aXa'.replace(r, 'b'), r.lastIndex].join()") ==
               "bXb,0"

      assert js("var r = /a/; r.lastIndex = 2; ['aXa'.replace(r, 'b'), r.lastIndex].join()") ==
               "bXa,2"
    end

    test "a group that does not take part gives undefined to the function and nothing to $n" do
      assert js(~S"""
             'ab'.replace(/(a)|(b)/g, function (m, p1, p2, at) {
               return '[' + [m, p1 === undefined, p2 === undefined, at].join() + ']';
             })
             """) == "[a,false,true,0][b,true,false,1]"

      assert js(~S"'ab'.replace(/(a)|(b)/g, '<$1|$2>')") == "<a|><|b>"
    end

    test "positions count UTF-16 code units" do
      assert js(~S"'😀é😀b'.replace(/b/, function (m, at) { return at; })") == "😀é😀5"
      assert js(~S"'😀aé😀a'.replace(/a/g, function (m, at) { return at; })") == "😀2é😀6"
      assert js(~S"'x😀y'.replace(/y/, '[$`|$\']')") == "x😀[x😀|]"
    end

    test "a changed flag getter is called, and the replace uses what it gives" do
      assert js("""
             var calls = 0;
             var d = Object.getOwnPropertyDescriptor(RegExp.prototype, 'global');
             Object.defineProperty(RegExp.prototype, 'global', {
               get: function () { calls++; return false; }, configurable: true
             });
             var r = 'aaa'.replace(/a/g, 'b');
             Object.defineProperty(RegExp.prototype, 'global', d);
             r + calls + 'aaa'.replace(/a/g, 'b')
             """) == "baa1bbb"
    end

    test "an own flags key, a changed exec and a subclass take the protocol" do
      assert js("""
             var r = /a/g; Object.defineProperty(r, 'flags', { value: '' });
             'aa'.replace(r, 'b')
             """) == "ba"

      assert js("""
             var r = /a/g, n = 0;
             r.exec = function (s) { n++; return n > 2 ? null : RegExp.prototype.exec.call(this, s); };
             'aaaa'.replace(r, 'b') + n
             """) == "bbaa3"

      assert js("""
             class R extends RegExp { exec(s) { return null; } }
             'aa'.replace(new R('a', 'g'), 'b') + new R('a').test('a')
             """) == "aafalse"
    end

    test "a non-number lastIndex of a non-global regexp is read once by ToLength" do
      assert js("""
             var n = 0, r = /a/;
             r.lastIndex = { valueOf: function () { n++; return 0; } };
             'aa'.replace(r, 'b') + n
             """) == "ba1"
    end

    test "a read-only lastIndex throws for the g flag" do
      assert js("""
             var r = /a/g; Object.defineProperty(r, 'lastIndex', { writable: false });
             try { 'a'.replace(r, 'b'); 'no' } catch (e) { e.name }
             """) == "TypeError"
    end

    test "sticky, named groups and lone surrogates" do
      assert js("var r = /a/y; r.lastIndex = 1; ['aab'.replace(r, 'X'), r.lastIndex].join()") ==
               "aXb,2"

      assert js(~S"'a-b'.replace(/(?<x>\w)-(?<y>\w)/, '$<y>-$<x>')") == "b-a"
      assert js(~S"('\ud800a' + 'a').replace(/a/g, 'b').length") == 3.0
      assert js(~S"'\ud800ab'.match(/a|b/g).join()") == "a,b"
    end

    test "match with the g flag and an empty match" do
      assert js("'abc'.match(/x*/g).length") == 4.0
      assert js("'a😀'.match(/(?:)/gu).length") == 3.0

      assert js("var r = /a/g; r.lastIndex = 3; ['aXa'.match(r).join(), r.lastIndex].join()") ==
               "a,a,0"

      assert js("'abc'.match(/x/g)") == nil
    end

    test "test follows lastIndex for the g and y flags" do
      assert js("""
             var r = /a/g, out = [];
             for (var i = 0; i < 4; i++) out.push(r.test('aXa'), r.lastIndex);
             out.join()
             """) == "true,1,true,3,false,0,true,1"

      assert js("var r = /a/y; [r.test('ba'), r.lastIndex, r.test('ab'), r.lastIndex].join()") ==
               "false,0,true,1"
    end
  end
end
