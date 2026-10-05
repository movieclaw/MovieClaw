"""「设置 → MovieClaw Cloud」页的视图装配（docs/design/cloud-push.md §7.1）。"""

from __future__ import annotations

from movieclaw_api.schemas.cloud import (
    CloudConnectionView,
    CloudDisconnectView,
    CloudNoticeView,
    CloudPairingView,
    CloudStatusView,
)
from movieclaw_api.services.cloud.service import get_cloud_service


async def build_status() -> CloudStatusView:
    service = get_cloud_service()
    setting = await service.load()
    pairing = service.pairing

    if setting.connected:
        state = "connected"
        health, health_message = service.health(setting)
    else:
        state = "pairing" if pairing is not None else "disconnected"
        health, health_message = None, None

    connection = None
    if setting.connected:
        connection = CloudConnectionView(
            instance_id=setting.instance_id,
            instance_name=setting.instance_name,
            account_display=setting.account_display,
            connected_at=setting.connected_at,
            last_renew_at=setting.last_renew_at,
            token_expires_at=setting.token_expires_at,
            scopes=setting.scopes,
            capabilities=setting.capabilities,
            limits=setting.limits,
        )

    last_disconnect = None
    if not setting.connected and setting.last_disconnect_reason:
        last_disconnect = CloudDisconnectView(
            reason=setting.last_disconnect_reason,
            message=setting.last_disconnect_message,
            at=setting.last_disconnect_at,
        )

    dismissed = set(setting.dismissed_notice_ids)
    return CloudStatusView(
        state=state,
        health=health,
        health_message=health_message,
        cloud_url=service.cloud_url(),
        custom_cloud_url=service.custom_cloud_url(),
        server_name=setting.instance_name or await service.default_instance_name(),
        pairing=(
            CloudPairingView(
                user_code=pairing.user_code,
                verification_uri=pairing.verification_uri,
                verification_uri_complete=pairing.verification_uri_complete,
                qrcode_image=pairing.qrcode_image,
                expires_at=pairing.expires_at,
                status=pairing.status,
                message=pairing.message,
                instance_name=pairing.instance_name,
            )
            if pairing is not None and not setting.connected
            else None
        ),
        connection=connection,
        last_disconnect=last_disconnect,
        report_stats=setting.report_stats,
        last_report=setting.last_report,
        last_report_at=setting.last_report_at,
        notices=[
            CloudNoticeView(id=n.id, level=n.level, message=n.message)
            for n in setting.notices
            if n.id not in dismissed
        ]
        if setting.connected
        else [],
    )
