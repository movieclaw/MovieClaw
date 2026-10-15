"""日志脱敏：URL 里的密钥不能写进日志文件（消息与异常堆栈都要覆盖）。"""

from __future__ import annotations

import logging

from movieclaw_api.core.logging import RedactingFormatter


def _format(record: logging.LogRecord) -> str:
    return RedactingFormatter("%(message)s").format(record)


def _record(msg: str, *args, exc_info=None) -> logging.LogRecord:
    return logging.LogRecord("httpx", logging.INFO, __file__, 1, msg, args, exc_info)


def test_httpx_request_line_hides_tmdb_api_key() -> None:
    line = _format(
        _record(
            'HTTP Request: %s %s "%s %d %s"',
            "GET",
            "https://api.themoviedb.org/3/search/multi?language=zh-CN&query=x&api_key=49182f77",
            "HTTP/1.1",
            200,
            "OK",
        )
    )
    assert "49182f77" not in line
    assert "api_key=***" in line
    # 其余参数与状态照常保留，排查网络问题还用得上
    assert "language=zh-CN&query=x" in line and "200 OK" in line


def test_passkey_and_token_variants_hidden() -> None:
    line = _format(
        _record("下载 https://pt.example/download.php?id=1&passkey=abc123&https=1 Token=t0k")
    )
    assert "abc123" not in line and "passkey=***&https=1" in line
    line = _format(_record("回调 https://x.example/cb?ACCESS_TOKEN=zzz#frag"))
    assert "zzz" not in line and "ACCESS_TOKEN=***#frag" in line


def test_exception_text_is_redacted() -> None:
    try:
        raise RuntimeError(
            "Client error '401' for url 'https://api.themoviedb.org/3/x?api_key=secret9'"
        )
    except RuntimeError:
        import sys

        line = _format(_record("TMDB 请求失败", exc_info=sys.exc_info()))
    assert "secret9" not in line
    assert "api_key=***" in line


def test_plain_message_unchanged() -> None:
    assert _format(_record("扫描完成：%d 部", 3)) == "扫描完成：3 部"


def test_cloud_drive_link_secrets_hidden() -> None:
    """网盘直链（strm）各家的签名参数与地址里的账号密码都不落日志，其余照常保留。"""
    cases = {
        "http://p115:8000?pickcode=ecmrzjm7k2lqlv0aa&file_name=a.mkv": "ecmrzjm7k2lqlv0aa",
        "http://alist:5244/d/115/a.mkv?sign=Xyz=:0": "Xyz=:0",
        "https://s3.example/a.mkv?X-Amz-Credential=AKIA1&X-Amz-Signature=deadbeef": "deadbeef",
        "https://oss.example/a.mkv?OSSAccessKeyId=LTAI9&Expires=1&Signature=c2ln": "LTAI9",
        "https://pan.example/a.mkv?auth_key=1700-0-0-f00d&bdstoken=b0b": "f00d",
        "https://cdn.example/a.mkv?sig=58d23a508&t=1700000000": "58d23a508",
        "http://user:p%40ss@nas:5005/smartstrm/115/a.mkv": "p%40ss",
    }
    for url, secret in cases.items():
        line = _format(_record("替播放器跟跳转失败，改由服务端转发：%s（%s）", url, "timeout"))
        assert secret not in line, line
    # 值到地址结束为止：紧跟的中文括号与报错原文照常保留
    line = _format(_record("跟跳转失败：%s（%s）", list(cases)[3], "Connection refused"))
    assert "Signature=***（Connection refused）" in line
    line = _format(_record("ffprobe 探测失败：%s", list(cases)[5]))
    assert "sig=***&t=1700000000" in line
    line = _format(_record("转发 %s", list(cases)[6]))
    assert "http://***@nas:5005/smartstrm/115/a.mkv" in line
    assert "bdstoken=***" in _format(_record(list(cases)[4]))
