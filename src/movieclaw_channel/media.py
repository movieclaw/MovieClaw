"""通道层共用的入站媒体下载：定义在 SDK（``movieclaw_sdk.channels``），这里转出给各平台沿用。

各平台拿图的前半段不同（微信是 CDN 密文 + AES 密钥，Telegram 先 getFile 换路径，Discord 直接给
带签名的链接），后半段一样：按上限流式拉字节，失败只丢这一张图。
"""

from __future__ import annotations

from movieclaw_sdk.channels import MAX_INBOUND_IMAGE_BYTES, MediaDownloadError, download_capped

__all__ = ["MAX_INBOUND_IMAGE_BYTES", "MediaDownloadError", "download_capped"]
