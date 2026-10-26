"""Trusted inline plugin for MovieClaw 0.36. No separate process or dependency.

Other accounts require opt-in and explicitly allowed libraries. A member can
privately view their own devices without publishing their activity. Host
playback logs remain private host data; no copy of the watch history is stored.
"""

from __future__ import annotations

import asyncio
import hashlib
import re
from contextlib import suppress
from datetime import datetime, timedelta
from pathlib import Path
from typing import Literal

from fastapi import APIRouter, Depends, Query
from fastapi.encoders import jsonable_encoder
from fastapi.responses import HTMLResponse, JSONResponse, Response
from pydantic import BaseModel, ConfigDict, Field, StrictBool
from sqlmodel import select

from movieclaw_api.api.deps import require_interactive
from movieclaw_api.exceptions import BadRequestException, NotFoundException
from movieclaw_api.plugins.keys import PLUGIN_DATA, PLUGIN_ROUTES
from movieclaw_api.services.auth import Principal
from movieclaw_api.services.library.access import (
    assert_item_visible,
    member_content_limit,
    member_visible_ids,
    visible_library_ids,
)
from movieclaw_db.engine import get_database
from movieclaw_db.models import Library, LibraryFile, MediaMetadata, Member, PlaybackLog
from movieclaw_db.models.base import utcnow
from movieclaw_kernel import plugin
from movieclaw_playback import activity

PLUGIN_ID = "watch-presence"
HISTORY_DAYS = 7
HISTORY_LIMIT = 20
LIVE_TTL = 45
ADULT_LIBRARY = re.compile(r"\b(?:AV|JAV|NSFW|XXX)\b|成人|色情", re.I)
ADULT_RATING = re.compile(r"^(?:XXX|X|R18\+?|NC-17|ADULT|成人)$", re.I)


class Preferences(BaseModel):
    model_config = ConfigDict(extra="forbid")
    share_enabled: StrictBool = False
    library_ids: list[int] = Field(default_factory=list, max_length=200)


def response(data):
    return JSONResponse(
        jsonable_encoder({"success": True, "data": data}),
        headers={"Cache-Control": "no-store", "Vary": "Cookie, Authorization"},
    )


def stamp(value: datetime) -> str:
    return value.isoformat(timespec="milliseconds") + "Z"


def session_key(play) -> str:
    value = f"{play.member_id}:{play.device_id}:{play.started_at.isoformat()}:{play.unit}"
    return hashlib.sha256(value.encode()).hexdigest()[:32]


def library_shareable(library) -> bool:
    return not library.exclude_from_home and not ADULT_LIBRARY.search(library.name)


def hidden_ids(prefs) -> set[int]:
    result = set()
    for row in (prefs or {}).get("home", {}).get("rows", []):
        if not row.get("hidden"):
            continue
        value = row.get("library_id")
        if value is None and str(row.get("id", "")).startswith("lib:"):
            value = row["id"][4:]
        with suppress(ValueError, TypeError):
            result.add(int(value))
    return result


async def owner_hidden(db, owner) -> set[int]:
    if owner == 0:
        from movieclaw_api.settings.schemas import get_ui_preferences

        return hidden_ids((await get_ui_preferences()).model_dump())
    member = await db.get(Member, owner)
    return hidden_ids(member.ui_prefs if member else None)


class Presence:
    def __init__(self, store):
        self.store = store
        # A settings change and its projections must not interleave. No public cache.
        self.lock = asyncio.Lock()

    async def prefs(self, owner: int) -> Preferences:
        saved = await self.store.get("preferences", scope=f"member:{owner}", default={})
        return Preferences.model_validate(saved)

    async def libraries(self, db, principal):
        visible = await visible_library_ids(db, principal)
        hidden = await owner_hidden(db, principal.owner_id)
        libraries = (await db.execute(select(Library).where(Library.id.in_(visible)))).scalars()
        return [
            {
                "id": lib.id,
                "name": lib.name,
                "shareable": bool(library_shareable(lib) and lib.id not in hidden),
                "reason": ""
                if library_shareable(lib) and lib.id not in hidden
                else "首页隐藏或成人媒体库不参与共享",
            }
            for lib in libraries
        ]

    async def settings(self, principal):
        async with self.lock, get_database().session() as db:
            prefs = await self.prefs(principal.owner_id)
            libraries = await self.libraries(db, principal)
            return response(
                {
                    **prefs.model_dump(),
                    "libraries": libraries,
                    "history_days": HISTORY_DAYS,
                    "history_limit": HISTORY_LIMIT,
                    "protocol_version": 1,
                }
            )

    async def save(self, principal, prefs):
        async with self.lock, get_database().session() as db:
            libraries = await self.libraries(db, principal)
            allowed = {lib["id"] for lib in libraries if lib["shareable"]}
            selected = set(prefs.library_ids)
            if prefs.share_enabled and not selected.issubset(allowed):
                raise BadRequestException("只能选择自己可浏览且可共享的媒体库")
            selected &= allowed
            if prefs.share_enabled and not selected:
                raise BadRequestException("请先选择至少一个允许共享的媒体库")
            prefs.library_ids = sorted(selected)
            await self.store.set(
                "preferences", prefs.model_dump(), scope=f"member:{principal.owner_id}"
            )
            return response(prefs.model_dump())

    async def owners(self, db, viewer):
        saved = await self.store.scopes("preferences", entity="member")
        visible = await visible_library_ids(db, viewer)
        visible -= await owner_hidden(db, viewer.owner_id)
        eligible = {
            lib.id
            for lib in (await db.execute(select(Library))).scalars()
            if library_shareable(lib)
        }
        members = {
            row.id: row
            for row in (await db.execute(select(Member))).scalars()
            if row.status == "active"
        }
        result = {}
        # Self access is private account access, independent of public consent.
        own_libraries = await visible_library_ids(db, viewer)
        if own_libraries:
            member = members.get(viewer.owner_id)
            result[viewer.owner_id] = {
                "member_id": viewer.owner_id,
                "name": (member.nickname or member.username) if member else "管理员",
                "is_self": True,
                "shared": own_libraries,
                "accessible": own_libraries,
            }
        for scope, value in saved.items():
            owner = int(scope.split(":")[1])
            if owner == viewer.owner_id or owner < 0 or (owner and owner not in members):
                continue
            prefs = Preferences.model_validate(value)
            if not prefs.share_enabled:
                continue
            owner_libraries = await member_visible_ids(db, owner)
            shared = set(prefs.library_ids) & eligible & owner_libraries
            shared -= await owner_hidden(db, owner)
            accessible = shared & visible
            if accessible:
                name = (members[owner].nickname or members[owner].username) if owner else "管理员"
                result[owner] = {
                    "member_id": owner,
                    "name": name,
                    "is_self": False,
                    "shared": shared,
                    "accessible": accessible,
                }
        return result

    async def project(self, db, viewer, owner, units, preferred=()):
        # Bind to the host's media model but never expose its admin activity response.
        from movieclaw_api.services.playback_activity import _load_unit_contexts, _target

        contexts = await _load_unit_contexts(db, set(units), set(preferred))
        if not contexts:
            return {}
        ratings = {
            meta.media_item_id: meta.content_rating
            for meta in (
                await db.execute(
                    select(MediaMetadata).where(
                        MediaMetadata.media_item_id.in_({unit[0] for unit in contexts})
                    )
                )
            ).scalars()
        }
        owner_limit = await member_content_limit(db, owner["member_id"])
        files = (
            await db.execute(
                select(LibraryFile).where(
                    LibraryFile.media_item_id.in_({unit[0] for unit in contexts}),
                    LibraryFile.in_place(),
                )
            )
        ).scalars()
        placements = {}
        for file in files:
            unit = (file.media_item_id, file.season_number, file.episode_number)
            placements.setdefault(unit, set()).add(file.library_id)
        targets = {}
        for unit, context in contexts.items():
            rating = ratings.get(unit[0])
            if (
                not owner.get("is_self") and ADULT_RATING.fullmatch(rating or "")
            ) or not owner_limit.allows(rating):
                continue
            libs = placements.get(unit, set())
            # Existing reports/logs do not always identify the physical file. If
            # the same episode also exists in a private library, fail closed.
            if not libs or (not owner.get("is_self") and not libs.issubset(owner["shared"])):
                continue
            accessible = libs & owner["accessible"]
            if not accessible:
                continue
            try:
                await assert_item_visible(db, viewer, unit[0])
            except NotFoundException:
                continue
            target = _target(unit, context, library_id=min(accessible), browsable=True).model_dump()
            targets[unit] = {"media": target, "duration_ms": context.duration_ms}
        return targets

    async def live(self, db, viewer, owners):
        plays, meters = activity.snapshot()
        now = utcnow()
        plays = [
            play
            for play in plays
            if play.member_id in owners and (now - play.last_report_at).total_seconds() <= LIVE_TTL
        ]
        result = {owner: [] for owner in owners}
        for owner, info in owners.items():
            sessions = [play for play in plays if play.member_id == owner]
            targets = await self.project(
                db,
                viewer,
                info,
                [play.unit for play in sessions],
                [meter.file_id for meter in meters if meter.file_id],
            )
            for play in sessions:
                if play.unit not in targets:
                    continue
                result[owner].append(
                    {
                        **targets[play.unit],
                        "entry_id": session_key(play),
                        "kind": "live",
                        "position_ms": play.position_ms,
                        "paused": play.paused,
                        "sampled_at": stamp(play.last_report_at),
                        "device": play.client.device_name,
                        "client": play.client.name,
                    }
                )
        return result

    async def members(self, viewer):
        async with self.lock, get_database().session() as db:
            owners = await self.owners(db, viewer)
            live = await self.live(db, viewer, owners)
            visible = []
            for owner, info in owners.items():
                if (
                    info["is_self"]
                    and not live[owner]
                    and not await self.history_rows(db, viewer, info)
                ):
                    continue
                visible.append(
                    {
                        "member_id": owner,
                        "name": info["name"],
                        "is_self": info["is_self"],
                        "sessions": live[owner],
                    }
                )
            return response(
                {
                    "members": visible,
                    "sampled_at": stamp(utcnow()),
                    "refresh_seconds": 8,
                }
            )

    async def history_rows(self, db, viewer, owner):
        # Bound both SQL scan and returned projection. No historical private titles
        # or counts are included. Re-check current consent on every request.
        rows = list(
            (
                await db.execute(
                    select(PlaybackLog)
                    .where(
                        PlaybackLog.member_id == owner["member_id"],
                        PlaybackLog.media_item_id.in_(
                            select(LibraryFile.media_item_id).where(
                                LibraryFile.library_id.in_(owner["accessible"]),
                                LibraryFile.in_place(),
                            )
                        ),
                        PlaybackLog.last_seen_at >= utcnow() - timedelta(days=HISTORY_DAYS),
                    )
                    .order_by(PlaybackLog.last_seen_at.desc(), PlaybackLog.id.desc())
                    .limit(200)
                )
            ).scalars()
        )
        targets = await self.project(
            db,
            viewer,
            owner,
            [(row.media_item_id, row.season_number, row.episode_number) for row in rows],
        )
        history = []
        seen = set()
        for row in rows:
            unit = (row.media_item_id, row.season_number, row.episode_number)
            if unit in seen or unit not in targets:
                continue
            seen.add(unit)
            history.append(
                {
                    **targets[unit],
                    "entry_id": str(row.id),
                    "kind": "history",
                    "position_ms": row.end_position_ms,
                    "watched_at": stamp(row.last_seen_at),
                    "completed": row.completed,
                    "device": row.device_name,
                    "client": row.client,
                }
            )
            if len(history) >= HISTORY_LIMIT:
                break
        return history

    async def history(self, viewer, member_id):
        async with self.lock, get_database().session() as db:
            owner = (await self.owners(db, viewer)).get(member_id)
            if owner is None:
                raise NotFoundException("没有可查看的共享记录")
            return response({"items": await self.history_rows(db, viewer, owner)})

    async def play(self, viewer, member_id, kind, entry_id):
        async with self.lock, get_database().session() as db:
            owners = await self.owners(db, viewer)
            owner = owners.get(member_id)
            if owner is None:
                raise NotFoundException("共享已关闭或影片不可访问")
            rows = (
                (await self.live(db, viewer, {member_id: owner}))[member_id]
                if kind == "live"
                else await self.history_rows(db, viewer, owner)
            )
            row = next((row for row in rows if row["entry_id"] == entry_id), None)
            if row is None:
                raise NotFoundException("观看状态已失效，请刷新列表")
            return response(row)


@plugin(PLUGIN_ID, title="服务器观看动态", inject=(PLUGIN_DATA, PLUGIN_ROUTES), reloadable=True)
async def apply(ctx):
    service = Presence(ctx.use(PLUGIN_DATA).scoped(ctx))
    router = APIRouter()

    @router.get("/settings", operation_id=f"plugins.{PLUGIN_ID}.settings.page")
    async def settings_page(viewer: Principal = Depends(require_interactive)):
        return HTMLResponse(
            (Path(__file__).parent / "settings.html").read_text(encoding="utf-8"),
            headers={"Cache-Control": "no-store"},
        )

    @router.get("/settings.js", operation_id=f"plugins.{PLUGIN_ID}.settings.script")
    async def settings_script(viewer: Principal = Depends(require_interactive)):
        return Response(
            (Path(__file__).parent / "settings.js").read_text(encoding="utf-8"),
            media_type="text/javascript",
            headers={"Cache-Control": "no-store"},
        )

    @router.get("/settings.css", operation_id=f"plugins.{PLUGIN_ID}.settings.style")
    async def settings_style(viewer: Principal = Depends(require_interactive)):
        return Response(
            (Path(__file__).parent / "settings.css").read_text(encoding="utf-8"),
            media_type="text/css",
            headers={"Cache-Control": "no-store"},
        )

    @router.get("/preferences", operation_id=f"plugins.{PLUGIN_ID}.preferences.get")
    async def preferences(viewer: Principal = Depends(require_interactive)):
        return await service.settings(viewer)

    @router.put("/preferences", operation_id=f"plugins.{PLUGIN_ID}.preferences.put")
    async def save_preferences(
        prefs: Preferences, viewer: Principal = Depends(require_interactive)
    ):
        return await service.save(viewer, prefs)

    @router.get("/members", operation_id=f"plugins.{PLUGIN_ID}.members")
    async def members(viewer: Principal = Depends(require_interactive)):
        return await service.members(viewer)

    @router.get("/members/{member_id}/history", operation_id=f"plugins.{PLUGIN_ID}.history")
    async def history(member_id: int, viewer: Principal = Depends(require_interactive)):
        return await service.history(viewer, member_id)

    @router.get("/members/{member_id}/play", operation_id=f"plugins.{PLUGIN_ID}.play")
    async def play(
        member_id: int,
        kind: Literal["live", "history"],
        entry_id: str = Query(max_length=64),
        viewer: Principal = Depends(require_interactive),
    ):
        return await service.play(viewer, member_id, kind, entry_id)

    ctx.use(PLUGIN_ROUTES).mount(ctx, router, zone="member")
