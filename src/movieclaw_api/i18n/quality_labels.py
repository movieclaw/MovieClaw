"""Reader-specific quality labels; matching ranks and stored snapshots remain neutral."""

from movieclaw_api.i18n.stored import reference
from movieclaw_enrich.models import TorrentAttrs
from movieclaw_matcher import QualitySnapshot, RuleSetSpec
from movieclaw_matcher.decision import DISC_SOURCE, USER_LOWEST_SOURCE, effective_ladder
from movieclaw_matcher.smart import SmartPolicy


def _label(parts: list) -> dict:
    return reference(
        "media.quality.label",
        parts={"message_list": parts, "separator_key": "media.quality.separator"},
    )


def duplicate_quality_reference(
    resolution: str | None, source: str | None, hdr: str | None = None
) -> dict:
    base = " ".join(part for part in (resolution, source) if part)
    return reference(
        "library.recycle.qualityLabel",
        base=base or reference("library.recycle.unknownSpec"),
        hdr=f" {hdr}" if hdr else "",
    )


def quality_reference(
    snapshot: QualitySnapshot | TorrentAttrs, spec: RuleSetSpec | SmartPolicy | None = None
) -> dict:
    resolution = snapshot.resolution or reference("media.quality.unknownResolution")
    source = snapshot.media_source or reference("media.quality.unknownSource")
    if (snapshot.media_source or "").casefold() == DISC_SOURCE.casefold():
        source = reference("media.quality.disc")
    elif snapshot.remux:
        source = "Remux"
    elif (snapshot.media_source or "").casefold() == USER_LOWEST_SOURCE:
        source = reference("media.quality.lowestManual")
    parts = [reference("media.quality.head", resolution=resolution, source=source)]
    if spec is not None:
        dimensions = effective_ladder(spec)
        if "hdr" in dimensions and snapshot.hdr:
            parts.append("/".join(snapshot.hdr))
        if "video_codec" in dimensions and snapshot.video_codec:
            parts.append(snapshot.video_codec)
        if "platform" in dimensions and snapshot.platforms:
            parts.append("/".join(snapshot.platforms))
    return _label(parts)


def upgrade_target_reference(spec: RuleSetSpec | SmartPolicy) -> dict | None:
    if spec.upgrade_source is None:
        return None
    resolution = (
        spec.resolution
        if isinstance(spec, SmartPolicy)
        else spec.cutoff_resolution
        or (spec.resolutions[0] if spec.resolutions else None)
        or "1080p"
    )
    source = {
        "web-dl": "WEB-DL",
        "blu-ray": reference("media.quality.bluray"),
        "remux": "Remux",
    }[spec.upgrade_source.value]
    parts = [reference("media.quality.head", resolution=resolution, source=source)]
    if not isinstance(spec, SmartPolicy):
        dimensions = effective_ladder(spec)
        if "hdr" in dimensions and spec.hdr_levels:
            parts.append(spec.hdr_levels[0])
        if "video_codec" in dimensions and spec.video_codecs:
            parts.append(spec.video_codecs[0])
        if "platform" in dimensions and spec.platforms:
            parts.append(spec.platforms[0])
    return _label(parts)
