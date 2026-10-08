defmodule Browser.Modal do
  @moduledoc """
  Modal dialogs. `showModal()` marks a `<dialog>` with `"@modal"` in the tree the page's scripts
  hand back. The dialog is drawn in the top layer: its user-agent rules (see `Browser.Style`)
  make it fixed, centred in the window and above everything; `dialog:modal` matches it.

  The box behind it, `::backdrop`, is made here: `backdrops/1` adds a stand-in element, the last
  child of `<html>`, for the topmost open modal dialog. The stand-in has the dialog's tag and
  attributes (so `dialog::backdrop` and `.name::backdrop` find it) and the dialog's number, made
  negative (less one): a click on it reaches the dialog's scripts as a click on the dialog itself.
  Only rules for `::backdrop` match it (see `Browser.CSS`).

  The rest of the page is inert while a modal dialog is open: `Browser.Forms.index/1` asks
  `count/1` for how many there are and treats the controls outside the last one as disabled.
  """

  @doc "How many open modal dialogs the tree has."
  def count(nodes) when is_list(nodes), do: nodes |> Enum.map(&count/1) |> Enum.sum()
  def count({:text, _}), do: 0

  def count({:element, tag, attrs, kids}),
    do: if(modal?(tag, attrs), do: 1, else: 0) + count(kids)

  @doc "Whether the element is an open dialog shown with `showModal()`."
  def modal?("dialog", attrs),
    do: List.keymember?(attrs, "@modal", 0) and List.keymember?(attrs, "open", 0)

  def modal?(_tag, _attrs), do: false

  @doc """
  The tree with a backdrop for the topmost open modal dialog, as the last child of `<html>`
  (where it shifts no other element's place among its siblings).
  """
  def backdrops(nodes) do
    case top(nodes, nil) do
      nil -> nodes
      attrs -> append(nodes, backdrop(attrs))
    end
  end

  # the attributes of the last modal dialog in document order
  defp top(nodes, found) when is_list(nodes), do: Enum.reduce(nodes, found, &top/2)
  defp top({:text, _}, found), do: found

  defp top({:element, tag, attrs, kids}, found),
    do: top(kids, if(modal?(tag, attrs), do: attrs, else: found))

  defp append(nodes, box) do
    case Enum.split_while(nodes, &(not match?({:element, "html", _, _}, &1))) do
      {before, [{:element, "html", attrs, kids} | rest]} ->
        before ++ [{:element, "html", attrs, kids ++ [box]} | rest]

      {all, []} ->
        all ++ [box]
    end
  end

  defp backdrop(attrs) do
    nid =
      case List.keyfind(attrs, "@nid", 0) do
        {_, n} when is_integer(n) -> -n - 1
        _ -> -1
      end

    own = for {k, _} = a <- attrs, k not in ["style", "@nid", "@edhost"], do: a
    {:element, "dialog", own ++ [{"@backdrop", ""}, {"@nid", nid}], []}
  end
end
