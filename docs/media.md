# Media: video, audio and iframe

Status: stage 1 is done. The other stages are a plan.

## Rule exception

The browser has no dependencies and uses no NIFs. Media decoding is the one exception.
A helper program links the ffmpeg libraries (libavformat, libavcodec, libswscale,
libswresample). The helper is a separate OS process. The browser talks to it through an
Erlang Port. If the helper crashes, the VM keeps running.

`scripts/install-toolchain.sh` installs ffmpeg, the libav development packages and
pkg-config (apt on Debian and Ubuntu, Homebrew on macOS). A new session has them.

## What works now (stage 1)

- `<video>` is a replaced element. It is 300 x 150 px, or the size of its `width` and
  `height` attributes. It draws a black box. With `controls`, it also draws a play
  button and a bar.
- `<audio controls>` is a 300 x 54 px bar. `<audio>` without `controls` is not shown.
- `<iframe>` is an inline box. It is 300 x 150 px, or the size of its `width` and
  `height` attributes. The page inside is not loaded. (Frames that a script makes with
  `document.write` or `srcdoc` use their own path.)
- A video with a `poster` shows the poster. Without one it shows its first frame, if the
  helper is built and the file is at most 32 MiB (the helper reads a file; streaming is
  a later step). The picture is scaled to the box like an image (`object-fit: contain`).
- Nothing plays. `HTMLMediaElement.play()` returns a promise and does nothing.

## Stages

1. Boxes (done).
2. The helper and its protocol (done, except hardware decoding). `native/browser_media/media_helper.c`,
   built by `mix media.build` (needs `cc`, `pkg-config` and the libav development files).
   `Browser.Media` starts the helper and gives frames and audio chunks. If the helper
   is not built, stage 1 stays as it is and `Browser.Media.available?/0` is false.
3. Sound. The helper or the browser must play the PCM. The audio clock is the master clock.
4. Drawing. The painter gets a video item. The session keeps the newest frame of each
   element and repaints only that rectangle.
5. The `HTMLMediaElement` API and events in JS.
6. Real controls, subtitles (WebVTT), HLS, then Media Source Extensions. Nested pages in
   iframes, then `postMessage`.

## Helper protocol

The Port uses `{:packet, 4}` binary frames: a 4-byte length, then the message. All numbers
are big-endian. There is one helper per media element. The helper decodes only when it is
asked, so the browser sets the timing. It reads a file: the browser saves the bytes of a
resource to a file first (streaming from a pipe is a later step).

Requests: `O path` (open), `S w h` (size of the frames to send, 0 0 = size of the video),
`V` (next video frame), `A` (next audio chunk), `K ms` (seek), `Q` (quit).

Replies:
- `I`: duration (ms), width, height, has video, has audio, frames per second times 1000,
  and the codec names ("video,audio").
- `v`: time (ms), width, height, RGBA bytes (scaled to the size from `S`).
- `a`: time (ms), s16 little-endian PCM, 2 channels, 48000 Hz.
- `E`: no more frames (`v`) or chunks (`a`).
- `K`: the seek is done. `X`: an error text.

After a seek, the helper drops the frames and chunks that are before the seek time.
The helper keeps packets for the stream that was not asked for (up to 4096 of each), so
the browser can read video and audio in any order.

## Left for stage 2

- Hardware decoding (VideoToolbox on macOS, VAAPI on Linux, with a software fallback).
  It needs a Mac to test. Today the helper decodes in software.
- Streaming bytes from the network into the helper (today: a file).
