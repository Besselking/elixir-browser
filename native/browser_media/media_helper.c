/*
 * browser_media: decodes audio and video with libav for the browser (docs/media.md).
 *
 * The browser starts this program as an Erlang Port with {:packet, 4}: each message on
 * stdin and stdout is a 4-byte big-endian length and a payload. All numbers in a payload
 * are big-endian. The helper never decodes by itself: it answers one request at a time,
 * so the browser decides the timing.
 *
 * Requests (first byte, then fields):
 *   'O' path        open a file (the browser has saved the bytes to a file)
 *   'S' u32 w, h    size of the video frames to send (0 0: the size of the video)
 *   'V'             decode the next video frame
 *   'A'             decode the next chunk of audio
 *   'K' u32 ms      seek; the next frames and chunks start at that time
 *   'Q'             quit
 *
 * Replies:
 *   'I' u32 duration_ms, u32 width, u32 height, u8 has_video, u8 has_audio,
 *       u32 frames_per_second*1000, string "video codec,audio codec"
 *   'v' u32 pts_ms, u32 w, u32 h, RGBA bytes
 *   'a' u32 pts_ms, s16 little-endian PCM, 2 channels, 48000 Hz
 *   'E' u8 'v' or 'a'      no more frames or chunks
 *   'X' string             error text
 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

#define AUDIO_RATE 48000
#define MAX_QUEUE 4096
#define MAX_MESSAGE (64u * 1024 * 1024)

typedef struct {
  AVPacket *items[MAX_QUEUE];
  int head, count;
} Queue;

static AVFormatContext *fmt;
static AVCodecContext *vdec, *adec;
static struct SwsContext *sws;
static struct SwrContext *swr;
static int vidx = -1, aidx = -1;
static Queue vq, aq;
static int out_w, out_h; /* requested frame size; 0 = native */
static int64_t vseek_ms = -1, aseek_ms = -1;
static int eof;

/* ---- messages ---------------------------------------------------------------- */

static int read_all(void *buf, size_t n) {
  uint8_t *p = buf;
  while (n > 0) {
    ssize_t r = read(0, p, n);
    if (r < 0 && errno == EINTR) continue;
    if (r <= 0) return -1;
    p += r;
    n -= (size_t)r;
  }
  return 0;
}

static int write_all(const void *buf, size_t n) {
  const uint8_t *p = buf;
  while (n > 0) {
    ssize_t r = write(1, p, n);
    if (r < 0 && errno == EINTR) continue;
    if (r <= 0) return -1;
    p += r;
    n -= (size_t)r;
  }
  return 0;
}

static void put32(uint8_t *p, uint32_t v) {
  p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v;
}

static uint32_t get32(const uint8_t *p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static void send_message(const uint8_t *head, size_t head_n, const uint8_t *body, size_t body_n) {
  uint8_t len[4];
  put32(len, (uint32_t)(head_n + body_n));
  if (write_all(len, 4) || write_all(head, head_n) || (body_n && write_all(body, body_n))) exit(1);
}

static void send_error(const char *text) {
  uint8_t head[1] = {'X'};
  send_message(head, 1, (const uint8_t *)text, strlen(text));
}

static void send_end(char which) {
  uint8_t head[2] = {'E', (uint8_t)which};
  send_message(head, 2, NULL, 0);
}

/* ---- queues of packets ---------------------------------------------------------- */

static void queue_push(Queue *q, AVPacket *pkt) {
  if (q->count == MAX_QUEUE) { /* drop the oldest */
    av_packet_free(&q->items[q->head]);
    q->head = (q->head + 1) % MAX_QUEUE;
    q->count--;
  }
  q->items[(q->head + q->count) % MAX_QUEUE] = pkt;
  q->count++;
}

static AVPacket *queue_pop(Queue *q) {
  if (q->count == 0) return NULL;
  AVPacket *pkt = q->items[q->head];
  q->head = (q->head + 1) % MAX_QUEUE;
  q->count--;
  return pkt;
}

static void queue_clear(Queue *q) {
  AVPacket *pkt;
  while ((pkt = queue_pop(q))) av_packet_free(&pkt);
}

/* The next packet of a stream (NULL at the end of the file): from its queue, else read
 * from the file, keeping the packets of the other stream for later. */
static AVPacket *next_packet(int stream) {
  Queue *mine = stream == vidx ? &vq : &aq;
  AVPacket *pkt = queue_pop(mine);
  if (pkt) return pkt;
  while (!eof) {
    pkt = av_packet_alloc();
    if (!pkt) return NULL;
    if (av_read_frame(fmt, pkt) < 0) {
      av_packet_free(&pkt);
      eof = 1;
      return NULL;
    }
    if (pkt->stream_index == stream) return pkt;
    if (pkt->stream_index == vidx) queue_push(&vq, pkt);
    else if (pkt->stream_index == aidx) queue_push(&aq, pkt);
    else av_packet_free(&pkt);
  }
  return NULL;
}

/* ---- opening ------------------------------------------------------------------ */

static AVCodecContext *open_decoder(AVStream *st) {
  const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
  if (!codec) return NULL;
  AVCodecContext *ctx = avcodec_alloc_context3(codec);
  if (!ctx) return NULL;
  if (avcodec_parameters_to_context(ctx, st->codecpar) < 0 || avcodec_open2(ctx, codec, NULL) < 0) {
    avcodec_free_context(&ctx);
    return NULL;
  }
  return ctx;
}

static void do_open(const char *path) {
  if (avformat_open_input(&fmt, path, NULL, NULL) < 0) return send_error("cannot open the file");
  if (avformat_find_stream_info(fmt, NULL) < 0) return send_error("no stream information");
  vidx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
  aidx = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
  if (vidx >= 0) vdec = open_decoder(fmt->streams[vidx]);
  if (aidx >= 0) adec = open_decoder(fmt->streams[aidx]);
  if (!vdec) vidx = -1;
  if (!adec) aidx = -1;
  if (vidx < 0 && aidx < 0) return send_error("no stream that can be decoded");

  uint32_t w = vdec ? (uint32_t)vdec->width : 0, h = vdec ? (uint32_t)vdec->height : 0;
  uint32_t fps = 0;
  if (vidx >= 0) {
    AVRational r = fmt->streams[vidx]->avg_frame_rate;
    if (r.den > 0) fps = (uint32_t)(r.num * 1000LL / r.den);
  }
  uint32_t ms = fmt->duration > 0 ? (uint32_t)(fmt->duration / (AV_TIME_BASE / 1000)) : 0;
  char names[128];
  snprintf(names, sizeof names, "%s,%s", vdec ? vdec->codec->name : "", adec ? adec->codec->name : "");

  uint8_t head[1 + 4 * 3 + 2 + 4];
  head[0] = 'I';
  put32(head + 1, ms);
  put32(head + 5, w);
  put32(head + 9, h);
  head[13] = vidx >= 0;
  head[14] = aidx >= 0;
  put32(head + 15, fps);
  send_message(head, sizeof head, (const uint8_t *)names, strlen(names));
}

/* ---- video ------------------------------------------------------------------- */

static int64_t pts_ms(AVStream *st, int64_t pts) {
  if (pts == AV_NOPTS_VALUE) return -1;
  return av_rescale_q(pts, st->time_base, (AVRational){1, 1000});
}

static void send_frame(AVFrame *frame) {
  int w = out_w > 0 ? out_w : frame->width, h = out_h > 0 ? out_h : frame->height;
  sws = sws_getCachedContext(sws, frame->width, frame->height, frame->format, w, h,
                             AV_PIX_FMT_RGBA, SWS_BILINEAR, NULL, NULL, NULL);
  if (!sws) return send_error("cannot scale the frame");
  size_t size = (size_t)w * h * 4;
  uint8_t *msg = malloc(13 + size);
  if (!msg) return send_error("out of memory");
  uint8_t *dst[4] = {msg + 13, NULL, NULL, NULL};
  int stride[4] = {w * 4, 0, 0, 0};
  sws_scale(sws, (const uint8_t *const *)frame->data, frame->linesize, 0, frame->height, dst, stride);
  int64_t ms = pts_ms(fmt->streams[vidx], frame->best_effort_timestamp);
  msg[0] = 'v';
  put32(msg + 1, ms < 0 ? 0 : (uint32_t)ms);
  put32(msg + 5, (uint32_t)w);
  put32(msg + 9, (uint32_t)h);
  send_message(msg, 13 + size, NULL, 0);
  free(msg);
}

static void do_video(void) {
  if (vidx < 0) return send_end('v');
  AVFrame *frame = av_frame_alloc();
  for (;;) {
    int r = avcodec_receive_frame(vdec, frame);
    if (r == 0) {
      int64_t ms = pts_ms(fmt->streams[vidx], frame->best_effort_timestamp);
      if (vseek_ms >= 0 && ms >= 0 && ms < vseek_ms) { /* before the seek target */
        av_frame_unref(frame);
        continue;
      }
      vseek_ms = -1;
      send_frame(frame);
      break;
    }
    if (r == AVERROR_EOF) { send_end('v'); break; }
    if (r != AVERROR(EAGAIN)) { send_error("video decoding failed"); break; }
    AVPacket *pkt = next_packet(vidx);
    if (pkt) {
      avcodec_send_packet(vdec, pkt);
      av_packet_free(&pkt);
    } else {
      avcodec_send_packet(vdec, NULL); /* flush at the end of the file */
    }
  }
  av_frame_free(&frame);
}

/* ---- audio ------------------------------------------------------------------- */

static int setup_resampler(void) {
  if (swr) return 0;
  AVChannelLayout out = AV_CHANNEL_LAYOUT_STEREO;
  if (swr_alloc_set_opts2(&swr, &out, AV_SAMPLE_FMT_S16, AUDIO_RATE, &adec->ch_layout,
                          adec->sample_fmt, adec->sample_rate, 0, NULL) < 0)
    return -1;
  return swr_init(swr);
}

static void send_audio(AVFrame *frame) {
  if (setup_resampler() < 0) return send_error("cannot resample the audio");
  int max = swr_get_out_samples(swr, frame->nb_samples) + 64;
  uint8_t *msg = malloc(5 + (size_t)max * 4);
  if (!msg) return send_error("out of memory");
  uint8_t *dst[1] = {msg + 5};
  int n = swr_convert(swr, dst, max, (const uint8_t **)frame->extended_data, frame->nb_samples);
  if (n < 0) { free(msg); return send_error("cannot resample the audio"); }
  int64_t ms = pts_ms(fmt->streams[aidx], frame->best_effort_timestamp);
  msg[0] = 'a';
  put32(msg + 1, ms < 0 ? 0 : (uint32_t)ms);
  send_message(msg, 5 + (size_t)n * 4, NULL, 0);
  free(msg);
}

static void do_audio(void) {
  if (aidx < 0) return send_end('a');
  AVFrame *frame = av_frame_alloc();
  for (;;) {
    int r = avcodec_receive_frame(adec, frame);
    if (r == 0) {
      int64_t ms = pts_ms(fmt->streams[aidx], frame->best_effort_timestamp);
      if (aseek_ms >= 0 && ms >= 0 && ms < aseek_ms) {
        av_frame_unref(frame);
        continue;
      }
      aseek_ms = -1;
      send_audio(frame);
      break;
    }
    if (r == AVERROR_EOF) { send_end('a'); break; }
    if (r != AVERROR(EAGAIN)) { send_error("audio decoding failed"); break; }
    AVPacket *pkt = next_packet(aidx);
    if (pkt) {
      avcodec_send_packet(adec, pkt);
      av_packet_free(&pkt);
    } else {
      avcodec_send_packet(adec, NULL);
    }
  }
  av_frame_free(&frame);
}

/* ---- seeking ----------------------------------------------------------------- */

static void do_seek(uint32_t ms) {
  if (!fmt) return send_error("no file is open");
  int64_t ts = (int64_t)ms * (AV_TIME_BASE / 1000);
  if (av_seek_frame(fmt, -1, ts, AVSEEK_FLAG_BACKWARD) < 0) return send_error("cannot seek");
  queue_clear(&vq);
  queue_clear(&aq);
  eof = 0;
  if (vdec) avcodec_flush_buffers(vdec);
  if (adec) avcodec_flush_buffers(adec);
  if (swr) swr_free(&swr);
  vseek_ms = aseek_ms = ms;
  uint8_t head[1] = {'K'};
  send_message(head, 1, NULL, 0);
}

/* ---- main loop ---------------------------------------------------------------- */

int main(void) {
  av_log_set_level(AV_LOG_ERROR);
  for (;;) {
    uint8_t len[4];
    if (read_all(len, 4)) return 0; /* the browser closed the pipe */
    uint32_t n = get32(len);
    if (n == 0 || n > MAX_MESSAGE) return 1;
    uint8_t *msg = malloc((size_t)n + 1);
    if (!msg || read_all(msg, n)) return 1;
    msg[n] = 0;
    switch (msg[0]) {
      case 'O': do_open((char *)msg + 1); break;
      case 'S':
        if (n >= 9) { out_w = (int)get32(msg + 1); out_h = (int)get32(msg + 5); }
        break;
      case 'V': fmt ? do_video() : send_error("no file is open"); break;
      case 'A': fmt ? do_audio() : send_error("no file is open"); break;
      case 'K': if (n >= 5) do_seek(get32(msg + 1)); break;
      case 'Q': free(msg); return 0;
      default: send_error("unknown request");
    }
    free(msg);
  }
}
