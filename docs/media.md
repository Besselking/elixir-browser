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
- Nothing plays. `HTMLMediaElement.play()` returns a promise and does nothing.

## Stages

1. Boxes (done).
2. The helper and its protocol. Build: `mix media.build` (`cc` and `pkg-config`). If the
   helper is missing, stage 1 stays as it is and `canPlayType` returns "".
3. Sound. The helper opens the audio output. The audio clock is the master clock.
4. Drawing. The painter gets a video item. The session keeps the newest frame of each
   element and repaints only that rectangle.
5. The `HTMLMediaElement` API and events in JS.
6. Real controls, subtitles (WebVTT), HLS, then Media Source Extensions. Nested pages in
   iframes, then `postMessage`.

## Protocol (stage 2)

The Port uses `{:packet, 4}` binary frames. There is one helper per media element.

Commands from the browser: `open`, `data` (bytes), `play`, `pause`, `seek MS`, `rate X`,
`volume X`, `close`.

Messages from the helper:
- `info`: duration, width, height, audio and video streams, codec names.
- `video_frame`: time in ms, width, height, RGBA bytes (scaled to the box size).
- `audio_chunk`: time in ms, s16 PCM, 48 kHz, stereo.
- `state`: `playing`, `paused`, `ended` or `error CODE`.

Hardware decoding: VideoToolbox on macOS and VAAPI on Linux (`av_hwdevice_ctx_create`).
The helper uses software decoding if hardware decoding is not available. It copies
hardware frames back to RGBA in the helper.
