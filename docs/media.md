# Media: video, audio and iframe

Status: stages 1 and 2 are done, and silent playback of video works (stage 4 without sound). The other stages are a plan.

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
  `height` attributes. The page in its `src` or `srcdoc` is loaded and drawn inside the
  box, with its own scripts and style sheets. Frames that a script makes with
  `document.write` work the same way.
- A video with a `poster` shows the poster. Without one it shows its first frame, if the
  helper is built and the file is at most 32 MiB (the helper reads a file; streaming is
  a later step). The picture is scaled to the box like an image (`object-fit: contain`).
- A video plays without sound. `video.play()`, `video.pause()` and a click on a video with
  `controls` start and stop it. A click on the bar jumps to that place in the video. The
  controls show a pause button and a progress line that moves while the video plays. A
  playing video hides its controls when the mouse has not moved over it for 2 seconds; they
  come back when the mouse moves. A video with a `poster` shows the frames once it plays. A video with `autoplay` starts when the page is shown, one with `loop` starts again at the end. Setting `currentTime` jumps to that time.
  `Browser.Media.Player` downloads the file (up to 256 MiB), decodes frame by frame and sends
  each frame in time. Each frame is drawn like a new picture of the same size. A late frame
  (more than 200 ms) is dropped. At the end the video goes back to its first frame, paused.
  A video of a tab that is not shown stops. A page that is left stops its videos.
- Scripts can read `paused`, `ended`, `currentTime`, `duration`, `readyState`, `videoWidth`
  and `videoHeight` of a video. The player tells the page about changes, and the page gets
  the events `loadedmetadata`, `loadeddata`, `canplay`, `play`, `playing`, `pause`,
  `timeupdate` (about every 250 ms), `ended` and `error`. A video with `controls` is opened when the page is shown (unless it has
  `preload="none"` or the file is bigger than 32 MiB), so its length is known before the
  first play. Other videos start their player on the first `play()` or click.
- A `<source>` is chosen by its `type`, and `canPlayType()` answers `"maybe"` or `"probably"` for the common types once the helper is built.
- Not done yet: sound, audio elements. `play()` returns a promise that is already
  resolved.

## Stages

1. Boxes (done).
2. The helper and its protocol (done, except hardware decoding). `native/browser_media/media_helper.c`,
   built by `mix media.build` (needs `cc`, `pkg-config` and the libav development files). `mix app.bundle` runs it first and puts the helper and its libav libraries into the app. On a Mac, install the tools with `brew install ffmpeg pkg-config`. If the helper cannot be built, the app has no video playback.
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
