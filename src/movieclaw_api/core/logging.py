"""全局日志配置：控制台输出 + 按天落盘。

设计要点：
- 所有模块统一走标准库 logging 的根 logger，本模块只负责一次性装配 Handler；
- 除控制台外，同时写入 ``{log_dir}/movieclaw-YYYY-MM-DD.log``（一天一个文件）。
  文件名在每次写入时按当天日期计算，跨天自动切换到新文件——相比标准库的
  TimedRotatingFileHandler（先写固定文件、到点再重命名），这种「写入时定名」
  的方式在多进程（uvicorn --reload、多 worker）下不存在重命名竞争，实现也更简单；
- 日志目录默认在 data/ 下，Docker 部署把 data/ 挂载为 volume 即可保证日志不丢；
- 每次跨天切换时顺手清理超过保留天数的旧日志，避免磁盘无限增长。

设置页的「系统日志」功能（api/routes/logs.py）直接按日期读取这里落盘的文件。
"""

import logging
import re
from datetime import date, timedelta
from pathlib import Path

# 日志文件命名：movieclaw-2026-07-18.log；正则同时被查看接口用于枚举可用日期
LOG_FILE_PREFIX = "movieclaw-"
LOG_FILE_SUFFIX = ".log"
LOG_FILE_PATTERN = re.compile(rf"^{LOG_FILE_PREFIX}(\d{{4}}-\d{{2}}-\d{{2}})\{LOG_FILE_SUFFIX}$")


def log_file_path(log_dir: str | Path, day: date) -> Path:
    """某一天的日志文件路径（写入与查看接口共用同一命名规则）。"""
    return Path(log_dir) / f"{LOG_FILE_PREFIX}{day.isoformat()}{LOG_FILE_SUFFIX}"


class DailyFileHandler(logging.Handler):
    """按天写盘的 Handler：每条日志写入「当天」的文件，跨天自动换文件。

    打开的文件句柄会缓存复用；只有日期变化时才重新打开，并在此时触发一次
    过期日志清理（删除超过 retention_days 的旧文件）。
    """

    def __init__(self, log_dir: str | Path, retention_days: int = 30) -> None:
        super().__init__()
        self.log_dir = Path(log_dir)
        self.retention_days = retention_days
        self._stream = None
        self._current_day: date | None = None

    def _ensure_stream(self) -> None:
        today = date.today()
        if self._stream is not None and self._current_day == today:
            return
        if self._stream is not None:
            self._stream.close()
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self._stream = log_file_path(self.log_dir, today).open("a", encoding="utf-8")
        self._current_day = today
        self._cleanup_expired(today)

    def _cleanup_expired(self, today: date) -> None:
        """删除超过保留天数的旧日志文件；清理失败不影响正常写日志。"""
        if self.retention_days <= 0:
            return
        cutoff = (today - timedelta(days=self.retention_days)).isoformat()
        try:
            for path in self.log_dir.iterdir():
                match = LOG_FILE_PATTERN.match(path.name)
                if match and match.group(1) < cutoff:
                    path.unlink(missing_ok=True)
        except OSError:
            pass

    def emit(self, record: logging.LogRecord) -> None:
        try:
            with self.lock:  # type: ignore[union-attr]
                self._ensure_stream()
                assert self._stream is not None
                self._stream.write(self.format(record) + "\n")
                self._stream.flush()
        except Exception:
            self.handleError(record)

    def close(self) -> None:
        with self.lock:  # type: ignore[union-attr]
            if self._stream is not None:
                self._stream.close()
                self._stream = None
        super().close()


class RedactingFormatter(logging.Formatter):
    """格式化后把 URL 查询参数里的密钥替换成 ``***``（消息正文与异常堆栈都覆盖）。

    第三方库会把完整请求地址写进日志：httpx 每次请求都有一条
    ``HTTP Request: GET https://api.themoviedb.org/...?api_key=...``，请求失败的异常
    文本里也带着同一个地址；PT 站的种子链接带 passkey。日志会落盘、会在设置页
    「系统日志」里查看、也常被用户贴出来求助，密钥不能留在里面。

    不直接调高 httpx 的日志级别：请求地址与状态码是排查网络问题的关键线索，
    只遮住密钥本身即可。放在 Formatter 而不是 Filter：格式化在 Handler 的异常保护内
    执行，消息参数不匹配之类的问题不会抛回业务代码；格式化后的整段文本也包含堆栈。
    """

    _SECRET_PARAM = re.compile(
        r"([?&](?:api_?key|access_?token|token|passkey|secret|sign|auth)=)[^&\s\"'#]+",
        re.IGNORECASE,
    )

    def format(self, record: logging.LogRecord) -> str:
        return self._SECRET_PARAM.sub(r"\1***", super().format(record))


def configure_logging(
    log_level: str = "INFO",
    log_dir: str | Path | None = None,
    retention_days: int = 30,
) -> None:
    """装配根 logger：控制台 + 按天落盘文件（可重复调用，不会重复挂 Handler）。"""
    root_logger = logging.getLogger()
    root_logger.setLevel(log_level.upper())

    formatter = RedactingFormatter(
        fmt="%(asctime)s | %(levelname)s | %(name)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    if not any(isinstance(h, logging.StreamHandler) for h in root_logger.handlers):
        handler = logging.StreamHandler()
        root_logger.addHandler(handler)

    if log_dir is not None and not any(
        isinstance(h, DailyFileHandler) for h in root_logger.handlers
    ):
        root_logger.addHandler(DailyFileHandler(log_dir, retention_days))

    for handler in root_logger.handlers:
        handler.setFormatter(formatter)
