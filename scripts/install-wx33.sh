#!/bin/bash
# Setup script: Elixir + OTP built against wxWidgets 3.3 (WebP images decode in wx).
# Replaces environment-setup-wx.sh when WebP support is wanted on Linux.
# Steps tested by hand in a cloud container on 2026-10-08 (wx 3.3.3, OTP 29.1.1).
# The script as a whole was not run end to end. Build time: about 30 minutes with 4 cores.
set -e
V=1.20.4
OTP=29.1.1   # latest tag in github.com/erlang/otp/releases
WX=3.3.3     # latest 3.3 release in github.com/wxWidgets/wxWidgets/releases
export DEBIAN_FRONTEND=noninteractive
apt-get update
# libwebp-dev: wx reads WebP through it. No webview package: wx 3.3 builds without it
# (the browser does not use wxWebView).
apt-get install -y build-essential autoconf m4 libssl-dev libncurses-dev \
  libgl-dev libglu1-mesa-dev libgtk-3-dev libwebp-dev libjpeg-dev libpng-dev libtiff-dev \
  xvfb unzip curl bzip2

# --- wxWidgets 3.3 ---
# --enable-compat30: OTP's wx still uses wxWidgets 3.0 names and refuses to build without it.
curl -fsSL -o /tmp/wx.tar.bz2 "https://github.com/wxWidgets/wxWidgets/releases/download/v$WX/wxWidgets-$WX.tar.bz2"
rm -rf /tmp/wx_src && mkdir /tmp/wx_src && tar -xjf /tmp/wx.tar.bz2 -C /tmp/wx_src --strip-components=1
(
  mkdir /tmp/wx_src/build && cd /tmp/wx_src/build
  ../configure --prefix=/usr/local/wx33 --with-gtk=3 --enable-shared --with-libwebp=sys \
    --with-opengl --enable-compat30 --disable-tests
  make -j"$(nproc)"
  make install
)
echo /usr/local/wx33/lib > /etc/ld.so.conf.d/wx33.conf && ldconfig
rm -rf /tmp/wx_src /tmp/wx.tar.bz2

# --- OTP, with its wx built against wx 3.3 ---
curl -fsSL -o /tmp/otp_src.tar.gz "https://github.com/erlang/otp/releases/download/OTP-$OTP/otp_src_$OTP.tar.gz"
rm -rf /tmp/otp_src && mkdir /tmp/otp_src && tar -xzf /tmp/otp_src.tar.gz -C /tmp/otp_src --strip-components=1
(
  cd /tmp/otp_src
  export ERL_TOP=$PWD PATH=/usr/local/wx33/bin:$PATH
  # OTP 29.1.1 gaps against wx 3.3, in the generated lib/wx/c_src/gen/wxe_init.cpp:
  #  - wxSTC_VISUALPROLOG_* (7 names) and wxSTC_CSS_MEDIA no longer exist
  #  - wxPreviewFrameModalityKind is now an enum class (no implicit int)
  sed -i -E '/wxSTC_VISUALPROLOG_(STRING_VERBATIM_EOL|STRING_VERBATIM_SPECIAL|STRING_VERBATIM|STRING_EOL_OPEN|CHARACTER_ESCAPE_ERROR|CHARACTER_TOO_MANY|CHARACTER)[,"]/d; /wxSTC_CSS_MEDIA"/d; s/rt\.make_int\((wxPreviewFrame_[A-Za-z]+)\)/rt.make_int(static_cast<int>(\1))/' \
    lib/wx/c_src/gen/wxe_init.cpp
  # the release tarball has dependency files with a build path of OTP's own CI
  grep -rl "/buildroot/otp" --include=deps.mk lib erts | xargs -r sed -i "s#/buildroot/otp#$ERL_TOP#g"
  ./configure --prefix=/usr/local/otp --without-javac --without-odbc --without-jinterface --without-megaco
  make -j"$(nproc)"
  rm -rf /usr/local/otp
  make install
)
rm -rf /tmp/otp_src /tmp/otp_src.tar.gz
for b in erl erlc escript; do ln -sf /usr/local/otp/bin/$b /usr/local/bin/$b; done
# fail the setup if the build quietly left wx out
erl -noshell -eval 'true = filelib:is_file(filename:join(code:lib_dir(wx), "priv/wxe_driver.so")), halt().'

curl -fsSL -o /tmp/elixir.zip "https://github.com/elixir-lang/elixir/releases/download/v$V/elixir-otp-29.zip"
rm -rf /usr/local/elixir && mkdir -p /usr/local/elixir && unzip -q /tmp/elixir.zip -d /usr/local/elixir
for b in elixir elixirc iex mix; do ln -sf /usr/local/elixir/bin/$b /usr/local/bin/$b; done
mix local.hex --force && mix local.rebar --force
