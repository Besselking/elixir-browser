defmodule Mix.Tasks.App.Bundle do
  @shortdoc "Builds a self-contained macOS .app (bundles Erlang and its dylibs)"

  @moduledoc """
  Builds `dist/<name>.app`, a double-clickable macOS app that embeds the Erlang
  runtime (ERTS), all OTP applications and the non-system dynamic libraries they
  need (e.g. wxWidgets), so it runs on Macs without Erlang installed.

      mix app.bundle [--name "Elixir Browser"] [--id dev.local.elixir-browser]
                     [--icon path/to/icon.png]

  Without `--icon` a placeholder icon is drawn with `scripts/make_icon.swift`.
  The bundle is only valid for the CPU architecture and macOS version it was
  built on, and is ad-hoc signed.
  """
  use Mix.Task

  @system_prefixes ["/usr/lib/", "/System/", "@"]

  @impl true
  def run(args) do
    unless match?({:unix, :darwin}, :os.type()), do: Mix.raise("app.bundle only works on macOS")

    {opts, _} =
      OptionParser.parse!(args, strict: [name: :string, id: :string, icon: :string])

    name = opts[:name] || "Elixir Browser"
    id = opts[:id] || "dev.local.elixir-browser"
    version = Mix.Project.config()[:version]

    app = Path.join(["dist", name <> ".app"])
    macos = Path.join(app, "Contents/MacOS")
    res = Path.join(app, "Contents/Resources")
    release = Path.join(res, "release")

    File.rm_rf!(app)
    File.mkdir_p!(macos)
    File.mkdir_p!(res)

    build_release(release)
    relocate_dylibs(release)
    sign_all(release)
    make_icon(res, opts[:icon])
    File.write!(Path.join(app, "Contents/Info.plist"), plist(name, id, version))
    write_launcher(macos)
    sign(app)

    Mix.shell().info("Built #{app} (#{du(app)})")
  end

  # -- release -----------------------------------------------------------------

  defp build_release(path) do
    cmd!("mix", ["release", "browser", "--overwrite", "--path", path, "--quiet"],
      env: [{"MIX_ENV", "prod"}]
    )
  end

  # -- dylib relocation --------------------------------------------------------

  defp relocate_dylibs(release) do
    ext = Path.join(release, "lib_ext")
    File.mkdir_p!(ext)

    roots = release |> macho_files() |> Enum.map(&{&1, &1})
    process(roots, ext, MapSet.new())
  end

  # queue of {file_in_bundle, original_path}; original is needed to resolve @rpath
  defp process([], _ext, _seen), do: :ok

  defp process([{file, orig} | rest], ext, seen) do
    {new_files, seen} =
      file
      |> deps(orig)
      |> Enum.reduce({[], seen}, fn {dep, real}, {acc, seen} ->
        base = Path.basename(real)
        dest = Path.join(ext, base)

        acc =
          if MapSet.member?(seen, base) do
            acc
          else
            File.cp!(real, dest)
            File.chmod!(dest, 0o755)
            cmd!("install_name_tool", ["-id", "@loader_path/" <> base, dest])
            [{dest, real} | acc]
          end

        rel = Path.relative_to(dest, Path.dirname(file), force: true)
        cmd!("install_name_tool", ["-change", dep, "@loader_path/" <> rel, file])
        {acc, MapSet.put(seen, base)}
      end)

    process(rest ++ new_files, ext, seen)
  end

  # Non-system dependencies as {install_name_as_written, resolved_real_path}.
  defp deps(file, orig) do
    {out, 0} = System.cmd("otool", ["-L", file])

    out
    |> String.split("\n", trim: true)
    |> tl()
    |> Enum.map(&(&1 |> String.trim() |> String.split(" (") |> hd()))
    |> Enum.reject(fn d ->
      d == file or Enum.any?(@system_prefixes -- ["@"], &String.starts_with?(d, &1)) or
        String.starts_with?(d, "@loader_path") or String.starts_with?(d, "@executable_path")
    end)
    |> Enum.map(fn d -> {d, resolve(d, orig)} end)
  end

  defp resolve("@rpath/" <> name = dep, orig) do
    dir = Path.dirname(orig)

    candidates =
      for rp <- rpaths(orig) do
        rp |> String.replace("@loader_path", dir) |> Path.join(name)
      end

    case Enum.find(candidates, &File.exists?/1) do
      nil -> Mix.raise("Cannot resolve #{dep} needed by #{orig}")
      found -> Path.expand(found) |> real_path()
    end
  end

  defp resolve(dep, _orig), do: real_path(dep)

  defp real_path(path) do
    {out, 0} = System.cmd("realpath", [path])
    String.trim(out)
  end

  defp rpaths(file) do
    {out, 0} = System.cmd("otool", ["-l", file])

    Regex.scan(~r/cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+?) \(offset/, out)
    |> Enum.map(&List.last/1)
  end

  defp macho_files(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.filter(fn f ->
      case File.open(f, [:read, :binary], &IO.binread(&1, 4)) do
        {:ok, <<magic::binary-size(4)>>} ->
          magic in [<<0xCF, 0xFA, 0xED, 0xFE>>, <<0xCA, 0xFE, 0xBA, 0xBE>>]

        _ ->
          false
      end
    end)
  end

  # -- icon / plist / launcher -------------------------------------------------

  defp make_icon(res, icon) do
    iconset =
      Path.join(System.tmp_dir!(), "iconset-#{System.unique_integer([:positive])}/icon.iconset")

    File.mkdir_p!(iconset)
    base = Path.join(iconset, "base.png")

    if icon,
      do: File.cp!(icon, base),
      else: cmd!("swift", ["scripts/make_icon.swift", base])

    for s <- [16, 32, 128, 256, 512], {suffix, px} <- [{"", s}, {"@2x", s * 2}] do
      out = Path.join(iconset, "icon_#{s}x#{s}#{suffix}.png")
      cmd!("sips", ["-z", "#{px}", "#{px}", base, "--out", out])
    end

    File.rm!(base)
    cmd!("iconutil", ["-c", "icns", iconset, "-o", Path.join(res, "AppIcon.icns")])
  end

  defp plist(name, id, version) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>CFBundleName</key><string>#{name}</string>
      <key>CFBundleDisplayName</key><string>#{name}</string>
      <key>CFBundleIdentifier</key><string>#{id}</string>
      <key>CFBundleExecutable</key><string>launcher</string>
      <key>CFBundleIconFile</key><string>AppIcon</string>
      <key>CFBundlePackageType</key><string>APPL</string>
      <key>CFBundleVersion</key><string>#{version}</string>
      <key>CFBundleShortVersionString</key><string>#{version}</string>
      <key>NSHighResolutionCapable</key><true/>
      <key>LSMinimumSystemVersion</key><string>11.0</string>
    </dict></plist>
    """
  end

  # exec (no fork) so the Dock/menu bar attribute the BEAM process to this bundle
  defp write_launcher(macos) do
    path = Path.join(macos, "launcher")

    File.write!(path, """
    #!/bin/bash
    DIR="$(cd "$(dirname "$0")/../Resources/release" && pwd)"
    export RELEASE_DISTRIBUTION=none
    # launched from the Dock there is no locale, and the toolkit would turn non-ASCII
    # text on the clipboard into question marks
    : "${LANG:=en_US.UTF-8}"
    export LANG
    exec "$DIR/bin/browser" start
    """)

    File.chmod!(path, 0o755)
  end

  # install_name_tool invalidates signatures, and arm64 kills code with a bad one.
  # `codesign --deep` does not reach Contents/Resources, so sign each binary.
  defp sign_all(release) do
    for f <- macho_files(release), do: cmd!("codesign", ["--force", "--sign", "-", f])
  end

  defp sign(app), do: cmd!("codesign", ["--force", "--deep", "--sign", "-", app])

  # -- helpers -----------------------------------------------------------------

  defp cmd!(cmd, args, opts \\ []) do
    case System.cmd(cmd, args, [stderr_to_stdout: true] ++ opts) do
      {_, 0} -> :ok
      {out, code} -> Mix.raise("#{cmd} #{Enum.join(args, " ")} failed (#{code}):\n#{out}")
    end
  end

  defp du(path) do
    {out, _} = System.cmd("du", ["-sh", path])
    out |> String.split() |> hd()
  end
end
