# Usage: python3 bench/serve.py DIR PORT
# The test server for the local mirror of bench/speedometer.exs. It serves DIR as
# `python3 -m http.server` does, but with a listen backlog of 128 connections in place of 5.
# With a backlog of 5, a burst of more than 5 connections (a page with many sub-resources,
# and up to 8 connections for each host in the browser) drops SYNs. The client sends the SYN
# again after 1 s, so a page change takes 1 s more (round 9 A/B: 7 of 16 runs).
import functools
import http.server
import sys


class Server(http.server.ThreadingHTTPServer):
    request_queue_size = 128
    daemon_threads = True


if __name__ == "__main__":
    d, port = sys.argv[1], int(sys.argv[2])
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=d)
    handler.protocol_version = "HTTP/1.1"
    with Server(("", port), handler) as s:
        s.serve_forever()
