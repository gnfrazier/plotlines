"""The sidecar's fill client against the real mirror app — issue #521.

`plotlines_core.mirror_fill_client` speaks #517's contract; this serves the
real `create_clip_app` with a fake layer filler over a socket, so the client
reads exactly what the mirror sends.
"""

from __future__ import annotations

import socket
import threading
import time

import uvicorn

from plotlines_core import mirror_fill_client as mfc
from plotlines_service.mirror_clip import create_clip_app
from plotlines_service.mirror_fill import FillWorker
from test_mirror_fill import FakeFiller, _store

KEY = "k"
BBOX = (-80.0, 36.0, -79.7, 36.2)


def _serve(app):
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="error"))
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    deadline = time.monotonic() + 10
    while not server.started:
        assert time.monotonic() < deadline
        time.sleep(0.02)
    return server, thread, f"http://127.0.0.1:{port}"


def test_request_then_poll_to_ready_and_every_refusal_is_an_answer(tmp_path) -> None:
    filler = FakeFiller()
    root = _store(tmp_path)
    worker = FillWorker(root, [filler], state_dir=tmp_path / "fs")
    server, thread, url = _serve(create_clip_app(root, tmp_dir=tmp_path / "scratch",
                                                 client_key=KEY, fill_worker=worker))
    try:
        first = mfc.request_fill(url, "fake", BBOX, client_key=KEY)
        assert first.fetching and first.fill_id and first.retry_after_s == 7
        filler.release.set()
        deadline = time.monotonic() + 5
        while mfc.fill_status(url, first.fill_id, client_key=KEY).fetching:
            assert time.monotonic() < deadline
            time.sleep(0.02)
        assert mfc.fill_status(url, first.fill_id, client_key=KEY).state == "ready"
        assert mfc.request_fill(url, "fake", BBOX, client_key=KEY).state == "ready"

        assert mfc.request_fill(url, "fake", (-175, 10, -174, 11), client_key=KEY).state == \
            "no_upstream_coverage"
        unkeyed = mfc.request_fill(url, "fake", BBOX)
        assert unkeyed.failed and unkeyed.state == "failed:unauthorized_client"
        assert mfc.request_fill(url, "weather", BBOX, client_key=KEY).state == \
            "failed:unknown_layer"
    finally:
        server.should_exit = True
        thread.join(5)
        worker.shutdown()


def test_an_unreachable_mirror_is_a_transient_answer_not_a_raise() -> None:
    answer = mfc.request_fill("http://127.0.0.1:9", "basemap", BBOX)
    assert answer.state == "failed:unreachable"
