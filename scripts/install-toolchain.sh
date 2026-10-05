#!/usr/bin/env bash
# Installs the toolchain the browser needs: Erlang/OTP 29 (with wx) and Elixir 1.20.
#   macOS:          Homebrew (brew install erlang elixir)
#   Debian/Ubuntu:  OTP built from source with wx under $PREFIX (default /usr/local), Elixir precompiled
# Versions match .tool-versions; asdf/mise users can run `asdf install` / `mise install` instead.
set -euo pipefail

cd "$(dirname "$0")/.."
OTP=$(awk '$1 == "erlang" { print $2 }' .tool-versions)
ELIXIR=$(awk '$1 == "elixir" { sub(/-otp-.*/, "", $2); print $2 }' .tool-versions)
OTP_MAJOR=${OTP%%.*}
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
  # build tools, wxWidgets (the prebuilt OTP from builds.hex.pm has no wx, which the GUI needs)
  $sudo apt-get install -y build-essential autoconf m4 libssl-dev libncurses-dev \
    libwxgtk3.2-dev libwxgtk-webview3.2-dev libgl-dev libglu1-mesa-dev libgtk-3-dev \
    xvfb unzip curl

  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT

  if ! "$PREFIX/otp/bin/erl" -noshell -eval "io:put_chars(erlang:system_info(otp_release)), halt()." 2>/dev/null | grep -qx "$OTP_MAJOR"; then
    curl -fsSL -o "$work/otp.tar.gz" "https://github.com/erlang/otp/releases/download/OTP-$OTP/otp_src_$OTP.tar.gz"
    mkdir "$work/otp" && tar -xzf "$work/otp.tar.gz" -C "$work/otp" --strip-components=1
    (
      cd "$work/otp"
      export ERL_TOP=$PWD
      ./configure --prefix="$PREFIX/otp" --without-javac --without-odbc --without-jinterface --without-megaco
      make -j"$(nproc)"
      $sudo rm -rf "$PREFIX/otp"
      $sudo make install
    )
  fi
  for b in erl erlc escript; do $sudo ln -sf "$PREFIX/otp/bin/$b" "$PREFIX/bin/$b"; done
  # fail if the build quietly left wx out
  "$PREFIX/otp/bin/erl" -noshell -eval 'true = filelib:is_file(filename:join(code:lib_dir(wx), "priv/wxe_driver.so")), halt().'

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
