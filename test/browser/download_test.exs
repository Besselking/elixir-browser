defmodule Browser.DownloadTest do
  # (the Downloads folder is an application setting: the tests set it one at a time)
  use ExUnit.Case, async: false
  alias Browser.Download

  setup do
    dir =
      Path.join(System.tmp_dir!(), "browser-downloads-#{System.unique_integer([:positive])}")

    old = Application.get_env(:browser, :downloads_dir)
    Application.put_env(:browser, :downloads_dir, dir)

    on_exit(fn ->
      if old,
        do: Application.put_env(:browser, :downloads_dir, old),
        else: Application.delete_env(:browser, :downloads_dir)

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp no_fetch(url), do: flunk("fetched #{url}")

  describe "file_name/2" do
    test "the download attribute is the name" do
      assert Download.file_name("speedometer-3.json", "blob:http://t.test/1") ==
               "speedometer-3.json"
    end

    test "path separators, colons and control characters become _" do
      assert Download.file_name("a/b\\c.txt", "blob:x") == "a_b_c.txt"
      assert Download.file_name("../../etc/passwd", "blob:x") == "_.._etc_passwd"
      assert Download.file_name("x\ny\0.txt", "blob:x") == "x_y_.txt"

      assert Download.file_name("speedometer-3-2026-10-16T12:00:00.000Z.json", "blob:x") ==
               "speedometer-3-2026-10-16T12_00_00.000Z.json"
    end

    test "leading dots and spaces go" do
      assert Download.file_name("..hidden", "blob:x") == "hidden"
      assert Download.file_name("  . x.txt ", "blob:x") == "x.txt"
    end

    test "an empty name takes the last part of the URL, or download" do
      assert Download.file_name("", "https://t.test/files/report%20one.pdf?x=1") ==
               "report one.pdf"

      assert Download.file_name(nil, "https://t.test/files/%2E%2E%2Fx") == "_x"
      assert Download.file_name("", "https://t.test/") == "download"
      assert Download.file_name("...", "blob:http://t.test/1") == "download"
      assert Download.file_name("", "data:text/plain,hi") == "download"
    end
  end

  test "numbered/2 puts the number before the extension" do
    assert Download.numbered("a.json", 0) == "a.json"
    assert Download.numbered("a.json", 2) == "a (2).json"
    assert Download.numbered("a.tar.gz", 1) == "a.tar (1).gz"
    assert Download.numbered("README", 1) == "README (1)"
    assert Download.numbered("x.", 1) == "x. (1)"
  end

  test "a blob is saved in the Downloads folder, which is made when it is not there", %{dir: dir} do
    refute File.exists?(dir)

    assert {:ok, path} =
             Download.save("blob:http://t.test/1", "score.json", ~S|{"score":42}|, &no_fetch/1)

    assert path == Path.join(dir, "score.json")
    assert File.read!(path) == ~S|{"score":42}|
  end

  test "a file that is there is not written over", %{dir: dir} do
    for n <- 0..2, do: Download.save("blob:x", "a.json", "#{n}", &no_fetch/1)
    assert File.read!(Path.join(dir, "a.json")) == "0"
    assert File.read!(Path.join(dir, "a (1).json")) == "1"
    assert File.read!(Path.join(dir, "a (2).json")) == "2"
  end

  test "data: and http URLs are fetched", %{dir: dir} do
    assert {:ok, path} = Download.save("data:text/plain;base64,aGk=", "", nil)
    assert path == Path.join(dir, "download")
    assert File.read!(path) == "hi"

    fetch = fn "https://t.test/f/r.csv" -> {:ok, "a,b", "https://t.test/f/r.csv"} end
    assert {:ok, path} = Download.save("https://t.test/f/r.csv", nil, nil, fetch)
    assert path == Path.join(dir, "r.csv")
    assert File.read!(path) == "a,b"

    assert {:error, "404"} =
             Download.save("https://t.test/x", "x", nil, fn _ -> {:error, "404"} end)
  end

  test "a blob URL whose blob is gone is an error" do
    assert {:error, _} = Download.save("blob:http://t.test/1", "a", nil, &no_fetch/1)
  end
end
