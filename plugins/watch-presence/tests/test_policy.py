"""Focused policy tests, using the same SDK and dependencies as the host."""

import os
import sys
from types import SimpleNamespace

import pytest
from pydantic import ValidationError

sys.path.insert(0, os.environ["WATCH_PRESENCE_SOURCE"])
from watch_presence import Preferences, hidden_ids, library_shareable, session_key


def test_consent_is_explicit_and_never_accepts_another_owner():
    assert Preferences().model_dump() == {"share_enabled": False, "library_ids": []}
    for value in ("true", 1, None):
        with pytest.raises(ValidationError):
            Preferences(share_enabled=value)
    with pytest.raises(ValidationError):
        Preferences(member_id=99)


def test_hidden_rows_use_ids_not_display_names_and_ignore_invalid_ids():
    assert hidden_ids(
        {
            "home": {
                "rows": [
                    {"id": "lib:5", "hidden": True},
                    {"library_id": 8, "hidden": True},
                    {"library_id": 9, "hidden": False},
                    {"id": "lib:bad", "hidden": True},
                ]
            }
        }
    ) == {5, 8}
    assert hidden_ids(None) == set()


@pytest.mark.parametrize(
    "name,hidden,expected",
    [
        ("电影", False, True),
        ("私人电影", True, False),
        ("成人", False, False),
        ("JAV", False, False),
        ("NSFW films", False, False),
        ("David movies", False, True),
    ],
)
def test_shareable_policy(name, hidden, expected):
    assert bool(library_shareable(SimpleNamespace(name=name, exclude_from_home=hidden))) is expected


def test_session_handles_are_opaque_and_change_when_a_new_play_starts():
    from datetime import datetime, timedelta

    play = SimpleNamespace(
        member_id=1,
        device_id="private-device-id",
        started_at=datetime(2026, 10, 12),
        unit=(3, 1, 2),
    )
    first = session_key(play)
    assert len(first) == 32 and "private-device" not in first
    assert session_key(play) == first
    play.started_at += timedelta(seconds=1)
    assert session_key(play) != first
