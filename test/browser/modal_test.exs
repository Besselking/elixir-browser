defmodule Browser.ModalTest do
  use ExUnit.Case, async: true

  alias Browser.{Forms, Layout, Modal, Page, Style}

  defp measure(text, style), do: String.length(text) * div(style.size, 2)

  # the page as it is after a script called `showModal()` on its dialogs
  defp modal_page(html, css \\ "") do
    page = Page.build("<style>#{css}</style>" <> html, "about:test")
    Page.from_raw(page, mark(page.raw), Style.default_env())
  end

  defp mark(nodes) when is_list(nodes), do: Enum.map(nodes, &mark/1)

  defp mark({:element, "dialog", attrs, kids}),
    do: {:element, "dialog", attrs ++ [{"@modal", ""}], mark(kids)}

  defp mark({:element, tag, attrs, kids}), do: {:element, tag, attrs, mark(kids)}
  defp mark(text), do: text

  defp lay(page), do: elem(Layout.layout(page.nodes, 800, &measure/2, 600), 0)
  defp word(items, text), do: Enum.find(items, &(&1[:text] == text))

  describe "the top layer" do
    test "the ring and caret of a field in a modal dialog are drawn above the dialog" do
      page = modal_page("<dialog open><input id=i placeholder=v></dialog>")

      cid =
        page.forms.controls |> Map.values() |> Enum.find(&(&1.tag == "input")) |> Map.get(:cid)

      {items, _} =
        Layout.layout(page.nodes, 800, &measure/2, 600, focus: %{cid: cid, caret: {0, 0}})

      for type <- [:ring, :caret] do
        item = Enum.find(items, &(&1.type == type))
        assert item.z == 2_147_483_647
      end
    end

    test "a modal dialog is centred in the window, above the page" do
      items = lay(modal_page("<p>behind</p><dialog open><p>inside</p></dialog>"))
      inside = word(items, "inside")

      assert inside.stick == :fixed
      assert inside.x > 300 and inside.x < 500
      assert inside.y > 250 and inside.y < 350
      assert inside.z == 2_147_483_647
      refute Map.has_key?(word(items, "behind"), :stick)
    end

    test "it stays above a later sibling with a stacking context" do
      items =
        lay(
          modal_page(
            "<div style='position:relative;z-index:5'><dialog open>d</dialog></div><div style='position:relative;z-index:99'>later</div>"
          )
        )

      assert word(items, "d").z > word(items, "later")[:z] || 0
    end

    test "a dialog that is not modal stays in the page" do
      page = Page.build("<p>behind</p><dialog open>plain</dialog>", "about:test")
      items = elem(Layout.layout(page.nodes, 800, &measure/2, 600), 0)

      refute Map.has_key?(word(items, "plain"), :stick)
      assert Modal.count(page.raw) == 0
    end
  end

  describe "the backdrop" do
    test "covers the window, behind the dialog, and takes the dialog's number" do
      page = modal_page("<p>behind</p><dialog open id=d>x</dialog>")
      items = lay(page)

      backdrop =
        Enum.find(
          items,
          &(&1.type == :rect and &1[:stick] == :fixed and &1.w == 800 and &1.h == 600)
        )

      assert backdrop.color == {0, 0, 0, 26}
      assert backdrop.z < word(items, "x").z
      assert backdrop.nid < 0
    end

    test "author rules for ::backdrop style it, and dialog rules do not" do
      page =
        modal_page(
          "<dialog open id=d>x</dialog>",
          "dialog::backdrop { background: rgb(255, 0, 0) } dialog { padding: 33px }"
        )

      items = lay(page)
      backdrop = Enum.find(items, &(&1.type == :rect and &1[:stick] == :fixed and &1.w == 800))
      assert backdrop.color == {255, 0, 0, 255} or backdrop.color == {255, 0, 0}
      # the padding is the dialog's, not the backdrop's
      assert backdrop.h == 600
    end

    test "there is none for a plain open dialog or a closed one" do
      page = Page.build("<dialog open>a</dialog><dialog>b</dialog>", "about:test")
      assert Modal.backdrops(page.raw) == page.raw
    end
  end

  describe "inert" do
    test "controls outside the open modal dialog cannot take focus" do
      page =
        modal_page(
          "<input id=a><dialog open><input id=b><button>ok</button></dialog><input id=c>"
        )

      controls = page.forms.controls

      assert for(c <- Map.values(controls), do: c.inert?) |> Enum.sort() == [
               false,
               false,
               true,
               true
             ]

      assert Forms.focus_order(controls) |> length() == 2
    end

    test "only the last of several modal dialogs takes part" do
      page =
        modal_page("<dialog open><input></dialog><dialog open><input><button>x</button></dialog>")

      assert length(Forms.focus_order(page.forms.controls)) == 2
    end

    test "the inert attribute takes a subtree out, in a page with no dialog" do
      page = Page.build("<input><div inert><input><button>b</button></div>", "about:test")
      assert length(Forms.focus_order(page.forms.controls)) == 1
    end
  end

  describe "selectors" do
    test ":modal and :open match, a plain dialog is not :modal" do
      css = "dialog:modal { color: rgb(1, 2, 3) } dialog:open { font-weight: bold }"
      items = lay(modal_page("<dialog open>m</dialog>", css))
      assert word(items, "m").color == {1, 2, 3}

      page = Page.build("<style>#{css}</style><dialog open>p</dialog>", "about:test")
      items = elem(Layout.layout(page.nodes, 800, &measure/2, 600), 0)
      refute word(items, "p").color == {1, 2, 3}
    end
  end

  describe "popovers" do
    defp open_popover(page) do
      mark = fn
        {:element, "div", attrs, kids}, f ->
          attrs =
            if List.keymember?(attrs, "popover", 0), do: attrs ++ [{"@popover", ""}], else: attrs

          {:element, "div", attrs, Enum.map(kids, &f.(&1, f))}

        {:element, t, a, k}, f ->
          {:element, t, a, Enum.map(k, &f.(&1, f))}

        other, _ ->
          other
      end

      Page.from_raw(page, Enum.map(page.raw, &mark.(&1, mark)), Style.default_env())
    end

    test "a popover is hidden until it is open, then centred in the window above the page" do
      page = Page.build("<p>behind</p><div popover>inside</div>", "about:test")
      refute word(lay(page), "inside")

      items = page |> open_popover() |> lay()
      inside = word(items, "inside")
      assert inside.stick == :fixed
      assert inside.x > 300 and inside.x < 500
      assert inside.z > Map.get(word(items, "behind"), :z, 0)
    end

    test "an open popover leaves the page's controls usable" do
      page = Page.build("<input><div popover><button>x</button></div>", "about:test")
      page = open_popover(page)
      assert Forms.focus_order(page.forms.controls) |> length() == 2
    end
  end
end
