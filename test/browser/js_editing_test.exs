defmodule Browser.JS.EditingTest do
  use ExUnit.Case, async: true
  alias Browser.JS.Runtime

  defp run(script, body) do
    {raw, _} =
      "<body>#{body}<script>#{script}</script></body>"
      |> Browser.HTML.parse()
      |> Browser.Forms.index()

    pid =
      Runtime.start(raw, %{
        url: "http://t.test/p",
        width: 800,
        height: 600,
        fetch: fn _ -> {:error, "404"} end
      })

    Runtime.run_scripts(pid)
  end

  defp logs(reply), do: for({:log, t} <- reply.console, do: t)
  defp errors(reply), do: for({:error, t} <- reply.console, do: t)

  @host ~S|<div id=e contenteditable="true"><div>Hello <b>world</b></div><p>two</p></div>|

  defp edit(script, body \\ @host) do
    r = run(~s|var e = document.getElementById("e"); e.focus(); #{script}|, body)
    assert errors(r) == []
    logs(r)
  end

  test "contentEditable and isContentEditable follow the attribute and inheritance" do
    assert edit(
             "console.log(e.contentEditable, e.isContentEditable, e.firstChild.isContentEditable)"
           ) ==
             ["true true true"]
  end

  test "text nodes can be split, measured in code points and normalized" do
    assert edit("""
           var t = e.firstChild.firstChild;
           var b = t.splitText(3);
           console.log(t.data + "|" + b.data + "|" + e.firstChild.childNodes.length);
           e.firstChild.normalize();
           console.log(e.firstChild.firstChild.data, e.firstChild.childNodes.length);
           """) == ["Hel|lo |3", "Hello  2"]
  end

  test "a range extracts, clones and surrounds contents" do
    assert edit("""
           var t = e.firstChild.firstChild;
           var r = document.createRange();
           r.setStart(t, 1); r.setEnd(t, 4);
           console.log(r.toString(), r.collapsed);
           var s = document.createElement("i");
           r.surroundContents(s);
           console.log(e.firstChild.innerHTML);
           """) == ["ell false", "H<i>ell</i>o <b>world</b>"]
  end

  test "execCommand bold wraps the selection and queryCommandState reports it" do
    assert edit("""
           var t = e.firstChild.firstChild;
           var s = getSelection();
           s.setBaseAndExtent(t, 0, t, 5);
           console.log(document.execCommand("bold"), document.queryCommandState("bold"));
           console.log(e.firstChild.innerHTML);
           """) == ["true true", "<b>Hello</b> <b>world</b>"]
  end

  test "insertText replaces the selection and fires beforeinput and input" do
    assert edit("""
           var seen = [];
           e.addEventListener("beforeinput", function (ev) { seen.push(ev.type + ":" + ev.inputType + ":" + ev.data); });
           e.addEventListener("input", function (ev) { seen.push(ev.type + ":" + ev.inputType); });
           var t = e.firstChild.firstChild;
           getSelection().setBaseAndExtent(t, 0, t, 5);
           document.execCommand("insertText", false, "Bye");
           console.log(seen.join(","));
           console.log(e.firstChild.textContent);
           """) == ["beforeinput:insertText:Bye,input:insertText", "Bye world"]
  end

  test "undo and redo restore earlier content" do
    assert edit("""
           var t = e.firstChild.firstChild;
           getSelection().collapse(t, 5);
           document.execCommand("insertText", false, "!");
           var a = e.firstChild.textContent;
           document.execCommand("undo");
           var b = e.firstChild.textContent;
           document.execCommand("redo");
           console.log(a + "|" + b + "|" + e.firstChild.textContent);
           """) == ["Hello! world|Hello world|Hello! world"]
  end

  test "lists are made from paragraphs and removed again" do
    assert edit("""
           var t = e.querySelector("p").firstChild;
           getSelection().collapse(t, 1);
           document.execCommand("insertUnorderedList");
           console.log(e.innerHTML);
           document.execCommand("insertUnorderedList");
           console.log(e.querySelectorAll("ul").length);
           """)
           |> List.last() == "0"
  end

  test "insertParagraph splits the block at the caret" do
    assert edit("""
           var t = e.querySelector("p").firstChild;
           getSelection().collapse(t, 1);
           document.execCommand("insertParagraph");
           var ps = e.querySelectorAll("p");
           console.log(ps.length, ps[0].textContent, ps[1].textContent);
           """) == ["2 t wo"]
  end

  test "the selection is reported to the screen side" do
    {raw, _} =
      "<body>#{@host}<script>var e=document.getElementById('e');e.focus();getSelection().collapse(e.firstChild.firstChild,2)</script></body>"
      |> Browser.HTML.parse()
      |> Browser.Forms.index()

    pid =
      Runtime.start(raw, %{
        url: "http://t.test/p",
        width: 800,
        height: 600,
        fetch: fn _ -> {:error, "404"} end
      })

    r = Runtime.run_scripts(pid)
    assert %{anchor: {_, 2}, focus: {_, 2}} = r.sel
  end

  test "focus() alone puts the caret at the start, so a command works on it" do
    assert edit(
             "console.log(document.execCommand('insertText', false, 'X'), e.firstChild.textContent)"
           ) ==
             ["true XHello world"]
  end

  test "Node has the node type constants and anchors report resolved addresses" do
    r =
      run(
        "console.log(Node.TEXT_NODE, Node.ELEMENT_NODE, document.getElementById('a').href)",
        "<a id=a href='x#y'>a</a>"
      )

    assert logs(r) == ["3 1 http://t.test/x#y"]
  end

  test "queries change nothing and keep a pending format for the next typing" do
    assert edit("""
           var t = e.firstChild.firstChild;
           getSelection().collapse(t, 5);
           document.execCommand("italic");
           document.queryCommandState("insertUnorderedList");
           document.queryCommandState("insertOrderedList");
           document.queryCommandEnabled("outdent");
           document.execCommand("insertText", false, "!");
           console.log(e.innerHTML);
           """) == ["<div>Hello<i>!</i> <b>world</b></div><p>two</p>"]
  end

  test "table rows, cells and indexes" do
    r =
      run(
        """
        var t = document.getElementById("t");
        var tr = t.rows[1];
        console.log(t.rows.length, tr.cells.length, tr.cells[1].cellIndex, tr.rowIndex, tr.sectionRowIndex, t.tBodies.length);
        """,
        "<table id=t><thead><tr><th>a</th></tr></thead><tbody><tr><td>1</td><td>2</td></tr></tbody></table>"
      )

    assert errors(r) == []
    assert logs(r) == ["2 2 1 1 0 1"]
  end

  test "setting location.hash to its current value stays on the page" do
    {raw, _} =
      Browser.HTML.parse(
        "<body><script>location.hash = 'a'; location.hash = 'a'; location.hash = ''</script></body>"
      )
      |> Browser.Forms.index()

    pid =
      Runtime.start(raw, %{
        url: "http://t.test/p",
        width: 800,
        height: 600,
        fetch: fn _ -> {:error, "404"} end
      })

    r = Runtime.run_scripts(pid)
    assert Enum.all?(r.outbox, &match?({:hash, _, _}, &1))
    assert length(r.outbox) == 2
  end
end
