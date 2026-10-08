#!/usr/bin/env bash
# Installs the toolchain the browser needs: Erlang/OTP 29 (with wx) and Elixir 1.20.
#   macOS:          Homebrew (brew install erlang elixir)
#   Debian/Ubuntu:  wxWidgets 3.3 (reads WebP images) and OTP built against it, from source under
#                   $PREFIX (default /usr/local), Elixir precompiled
# Versions match .tool-versions; asdf/mise users can run `asdf install` / `mise install` instead.
#
# The Linux source build takes 30+ minutes. To skip it, the script first tries a prebuilt archive of
# $PREFIX/otp and $PREFIX/wx33 (a release asset of this repository, one per OTP, wx and Ubuntu version).
# It checks the SHA-256 sum and, if the download or the check fails, builds from source.
#   scripts/install-toolchain.sh --pack OUT.tar.gz   after an install: write the archive and OUT.tar.gz.sha256
#   PREBUILT_URL=...   use another archive location (PREBUILT_URL=none: always build from source)
set -euo pipefail

pack=""
if [ "${1:-}" = "--pack" ]; then
  pack=${2:?usage: install-toolchain.sh --pack OUT.tar.gz}
  case "$pack" in /*) ;; *) pack=$PWD/$pack ;; esac
fi

cd "$(dirname "$0")/.."
OTP=$(awk '$1 == "erlang" { print $2 }' .tool-versions)
ELIXIR=$(awk '$1 == "elixir" { sub(/-otp-.*/, "", $2); print $2 }' .tool-versions)
OTP_MAJOR=${OTP%%.*}
WX=3.3.3 # latest 3.3 release in github.com/wxWidgets/wxWidgets/releases
PREFIX=${PREFIX:-/usr/local}

sudo=""
[ "$(id -u)" -eq 0 ] || sudo="sudo"

case "$(uname -s)" in
Darwin)
  command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh" >&2; exit 1; }
  brew install erlang elixir wxwidgets
  ;;
Linux)
  command -v apt-get >/dev/null || { echo "Only Debian/Ubuntu is supported; use asdf or mise elsewhere." >&2; exit 1; }
  export DEBIAN_FRONTEND=noninteractive
  $sudo apt-get update
  # build tools and the libraries wxWidgets needs (the prebuilt OTP from builds.hex.pm has no wx,
  # which the GUI needs); libwebp-dev is what lets wx read WebP
  $sudo apt-get install -y build-essential autoconf m4 libssl-dev libncurses-dev \
    libgl-dev libglu1-mesa-dev libgtk-3-dev libwebp-dev libjpeg-dev libpng-dev libtiff-dev \
    xvfb unzip curl bzip2

  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT

  have_toolchain() {
    "$PREFIX/otp/bin/erl" -noshell -eval "io:put_chars(erlang:system_info(otp_release)), halt()." 2>/dev/null | grep -qx "$OTP_MAJOR" &&
      [ -x "$PREFIX/wx33/bin/wx-config" ]
  }

  if [ -z "$pack" ] && ! have_toolchain; then
    # prebuilt archive: the build is only valid for the same OS release, so the name has it
    . /etc/os-release
    asset="toolchain-otp$OTP-wx$WX-$ID$VERSION_ID-$(uname -m).tar.gz"
    url=${PREBUILT_URL:-https://github.com/Besselking/elixir-browser/releases/download/toolchain/$asset}
    if [ "$url" != none ] &&
      curl -fsSL -o "$work/prebuilt.tar.gz" "$url" &&
      curl -fsSL -o "$work/prebuilt.sha256" "$url.sha256" &&
      [ "$(sha256sum <"$work/prebuilt.tar.gz" | cut -d' ' -f1)" = "$(cut -d' ' -f1 <"$work/prebuilt.sha256")" ]; then
      $sudo rm -rf "$PREFIX/otp" "$PREFIX/wx33"
      $sudo tar -xzf "$work/prebuilt.tar.gz" -C "$PREFIX"
      echo "$PREFIX/wx33/lib" | $sudo tee /etc/ld.so.conf.d/wx33.conf >/dev/null
      $sudo ldconfig
      echo "Installed the prebuilt toolchain $asset"
    else
      echo "No usable prebuilt toolchain; building from source." >&2
    fi
  fi

  if ! have_toolchain; then
    # wxWidgets 3.3. --enable-compat30: OTP's wx still uses wxWidgets 3.0 names.
    curl -fsSL -o "$work/wx.tar.bz2" "https://github.com/wxWidgets/wxWidgets/releases/download/v$WX/wxWidgets-$WX.tar.bz2"
    mkdir "$work/wx" && tar -xjf "$work/wx.tar.bz2" -C "$work/wx" --strip-components=1
    (
      # a directory of our own: the tarball already has a build/ directory
      mkdir "$work/wx-build" && cd "$work/wx-build"
      "$work/wx/configure" --prefix="$PREFIX/wx33" --with-gtk=3 --enable-shared --with-libwebp=sys \
        --with-opengl --enable-compat30 --disable-tests
      make -j"$(nproc)"
      $sudo make install
    )
    echo "$PREFIX/wx33/lib" | $sudo tee /etc/ld.so.conf.d/wx33.conf >/dev/null
    $sudo ldconfig

    curl -fsSL -o "$work/otp.tar.gz" "https://github.com/erlang/otp/releases/download/OTP-$OTP/otp_src_$OTP.tar.gz"
    mkdir "$work/otp" && tar -xzf "$work/otp.tar.gz" -C "$work/otp" --strip-components=1
    (
      cd "$work/otp"
      export ERL_TOP=$PWD PATH="$PREFIX/wx33/bin:$PATH"
      # OTP 29.1.1 gaps against wx 3.3, in the generated lib/wx/c_src/gen/wxe_init.cpp:
      #  - wxSTC_VISUALPROLOG_* (7 names) and wxSTC_CSS_MEDIA no longer exist
      #  - wxPreviewFrameModalityKind is now an enum class (no implicit int)
      sed -i -E '/wxSTC_VISUALPROLOG_(STRING_VERBATIM_EOL|STRING_VERBATIM_SPECIAL|STRING_VERBATIM|STRING_EOL_OPEN|CHARACTER_ESCAPE_ERROR|CHARACTER_TOO_MANY|CHARACTER)[,"]/d; /wxSTC_CSS_MEDIA"/d; s/rt\.make_int\((wxPreviewFrame_[A-Za-z]+)\)/rt.make_int(static_cast<int>(\1))/' \
        lib/wx/c_src/gen/wxe_init.cpp
      # the release tarball has dependency files with a build path of OTP's own CI
      grep -rl "/buildroot/otp" --include=deps.mk lib erts | xargs -r sed -i "s#/buildroot/otp#$ERL_TOP#g"
      ./configure --prefix="$PREFIX/otp" --without-javac --without-odbc --without-jinterface --without-megaco
      make -j"$(nproc)"
      $sudo rm -rf "$PREFIX/otp"
      $sudo make install
    )
  fi
  for b in erl erlc escript; do $sudo ln -sf "$PREFIX/otp/bin/$b" "$PREFIX/bin/$b"; done
  # fail if the build quietly left wx out
  "$PREFIX/otp/bin/erl" -noshell -eval 'true = filelib:is_file(filename:join(code:lib_dir(wx), "priv/wxe_driver.so")), halt().'

  if [ -n "$pack" ]; then
    tar -czf "$pack" -C "$PREFIX" otp wx33
    (cd "$(dirname "$pack")" && sha256sum "$(basename "$pack")" >"$pack.sha256")
    echo "Wrote $pack"
  fi

  curl -fsSL -o "$work/elixir.zip" "https://github.com/elixir-lang/elixir/releases/download/v$ELIXIR/elixir-otp-$OTP_MAJOR.zip"
  $sudo rm -rf "$PREFIX/elixir" && $sudo mkdir -p "$PREFIX/elixir"
  $sudo unzip -q "$work/elixir.zip" -d "$PREFIX/elixir"
  for b in elixir elixirc iex mix; do $sudo ln -sf "$PREFIX/elixir/bin/$b" "$PREFIX/bin/$b"; done
  ;;
*)
  echo "Unsupported OS; use asdf or mise with .tool-versions." >&2
  exit 1
  ;;
esac

export ELIXIR_ERL_OPTIONS="+fnu"
mix local.hex --force
mix local.rebar --force
elixir --version
