defmodule Browser.Media.ControlsTest do
  use ExUnit.Case, async: true
  alias Browser.Media.Controls

  test "the controls differ with the state" do
    paused = Controls.ops(320, 180, nil)
    playing = Controls.ops(320, 180, %{playing: true, frac: 0.5, visible: true})
    hidden = Controls.ops(320, 180, %{playing: true, frac: 0.5, visible: false})

    assert paused != playing
    assert hidden == []
    assert Controls.ops(320, 180, %{playing: true, frac: 0.2}) != playing
  end

  test "apply/2 swaps the ops of the controls of the video with that element number" do
    controls = %{type: :svg, video_controls: true, nid: 7, w: 320, h: 180, ops: :old}
    other = %{type: :svg, nid: 8, w: 10, h: 10, ops: :keep}
    items = [controls, other]

    assert Controls.apply(items, %{}) == items

    assert [%{ops: ops}, ^other] =
             Controls.apply(items, %{7 => %{playing: true, frac: 0.0, visible: true}})

    assert ops == Controls.ops(320, 180, %{playing: true, frac: 0.0, visible: true})
  end
end
