"""Isolated network acceptance: real local HTTP probes and a recorded restart request."""

import json
import os
from pathlib import Path

from fastapi.responses import Response
from tests.e2e._smart_api_launcher import app

from movieclaw_api.services import app_config

root = Path(os.environ["E2E_NETWORK_ROOT"])
probes = []


def record_restart(code=app_config.RESTART_EXIT_CODE):
    path = root / "restart-requests.json"
    values = json.loads(path.read_text()) if path.exists() else []
    path.write_text(json.dumps([*values, code]))


app_config.schedule_restart = record_restart


@app.get("/t/p/{path:path}")
async def local_image_probe(path: str):
    probes.append(path)
    return Response(b"isolated network probe", media_type="application/octet-stream")


@app.get("/__lab/network/state")
async def fixture_state():
    path = root / "restart-requests.json"
    return {"probes": probes, "restarts": json.loads(path.read_text()) if path.exists() else []}
