"""管理员密码离线重置入口（忘记密码时的唯一找回通道）。

    python -m movieclaw_api.reset_password            # 重置密码
    python -m movieclaw_api.reset_password --show     # 只看用户名，不做修改

为什么是"离线命令"而不是网页上的「忘记密码」
--------------------------------------------
自托管软件没有可信的第三方来证明"你是账号主人"：没有强制绑定的邮箱/手机，
真做邮件找回就得先要求每个部署者配好 SMTP——对着一台家里的 NAS，这既做不到
也没必要。所以身份证明换一个更硬的东西：**能直接访问 ``data/`` 目录，就是
这台机器的主人**。

这与主密钥文件（``data/.secret_key``）的信任边界完全一致：能碰数据目录的人
本来就能解密全部配置、直接改数据库，多一个改密入口不降低任何安全性；反过来，
碰不到数据目录的人（比如公网上的攻击者）也就摸不到这条路径。Jellyfin、
Vaultwarden、Gitea 的密码找回都是同款思路。

⚠️ 与之对应的红线写在 ``services.auth.reset_admin_password`` 上：那个函数不
校验原密码，**绝不可挂到任何 HTTP 路由上**。

保全配置
--------
整个过程只覆写"管理员密码哈希"这一个字段，用户名、昵称、站点、下载器、媒体库
等其余所有配置与数据原样不动。

成员（非超管）忘记密码不需要本命令：超管在「设置 → 成员管理」里点一下重置即可。
"""

from __future__ import annotations

import argparse
import asyncio
import getpass
import logging
import os
import secrets
import sys
from pathlib import Path

from movieclaw_api.i18n import t, use_locale

# 密码长度下限与网页首次引导保持一致（schemas/auth.py 的 BootstrapRequest）
MIN_PASSWORD_LENGTH = 8
MAX_PASSWORD_LENGTH = 128


async def _bootstrap_runtime() -> None:
    """装配离线运行所需的最小内核：数据库引擎 → 加密器 → 配置存储。

    刻意**不跑数据库迁移**：本命令只改一个字段，不该在用户着急找回密码时顺手
    动表结构；表结构升级仍由应用正常启动时自动完成（见 lifespan.py）。
    """
    from movieclaw_api.core.config import get_settings
    from movieclaw_api.settings import init_setting_store
    from movieclaw_db.crypto import init_secret_box
    from movieclaw_db.engine import init_db

    settings = get_settings()
    init_db(settings.database_url)
    init_secret_box(settings.master_key, Path(settings.secret_key_file))
    init_setting_store()


def _database_file(database_url: str) -> Path | None:
    """从 SQLite 连接串里取出数据库文件路径；非 SQLite 返回 None（不做存在性检查）。"""
    prefix = "sqlite+aiosqlite:///"
    if not database_url.startswith(prefix):
        return None
    return Path(database_url[len(prefix) :])


def _terminal_locale() -> str | None:
    """终端声明的语言（LC_ALL / LC_MESSAGES / LANG）；没声明或认不出返回 None。"""
    for name in ("LC_ALL", "LC_MESSAGES", "LANG"):
        value = os.environ.get(name, "").lower()
        if value.startswith("zh"):
            return "zh-Hans"
        if value.startswith("en"):
            return "en"
    return None


def _check_data_dir() -> str | None:
    """数据库文件不存在时，返回一条可行动的提示（说明大概率跑错了地方）。"""
    from movieclaw_api.core.config import get_settings

    db_file = _database_file(get_settings().database_url)
    if db_file is None or db_file.is_file():
        return None
    return t("auth.resetPassword.dataDirMissing", path=str(db_file.resolve()))


def _read_new_password(supplied: str | None) -> tuple[str, bool]:
    """确定新密码，返回 (密码, 是否为随机生成)。

    三种来源，按"越不容易泄露越优先"排布：
    - ``--password``：脚本化场景；会留在 shell 历史里，帮助文本已提示；
    - 交互终端（``docker exec -it``）：getpass 两次输入，不回显、不进历史；
    - 非交互（NAS 图形界面的一键执行、``docker exec`` 不带 -it）：随机生成
      并打印——总比让用户在管道里裸传密码强。
    """
    if supplied is not None:
        return supplied, False
    if not sys.stdin.isatty():
        return secrets.token_urlsafe(12), True

    while True:
        first = getpass.getpass(t("auth.resetPassword.prompt"))
        if len(first) < MIN_PASSWORD_LENGTH:
            print(t("auth.resetPassword.tooShortRetry", min=MIN_PASSWORD_LENGTH), file=sys.stderr)
            continue
        if first != getpass.getpass(t("auth.resetPassword.confirm")):
            print(t("auth.resetPassword.mismatch"), file=sys.stderr)
            continue
        return first, False


def _validate(password: str) -> None:
    if len(password) < MIN_PASSWORD_LENGTH:
        raise SystemExit(t("auth.resetPassword.tooShort", min=MIN_PASSWORD_LENGTH))
    if len(password) > MAX_PASSWORD_LENGTH:
        raise SystemExit(t("auth.resetPassword.tooLong", max=MAX_PASSWORD_LENGTH))


async def _run(args: argparse.Namespace) -> int:
    with use_locale(_terminal_locale() or "zh-Hans"):
        hint = _check_data_dir()
    if hint:
        print(hint, file=sys.stderr)
        return 1

    await _bootstrap_runtime()

    from movieclaw_api.services.locale_preferences import member_locale
    from movieclaw_db.engine import dispose_db

    try:
        # 终端没声明语言（Docker 里常见）：跟管理员在网页上用的语言
        locale = _terminal_locale() or await member_locale(0)
        with use_locale(locale):
            return await _reset(args)
    finally:
        await dispose_db()


async def _reset(args: argparse.Namespace) -> int:
    from movieclaw_api.services import auth as auth_service

    account = await auth_service.get_admin_account()
    if not account.password_hash:
        print(t("auth.resetPassword.notInitialized"), file=sys.stderr)
        return 1

    if args.show:
        print(t("auth.resetPassword.username", username=account.username))
        return 0

    new_password, generated = _read_new_password(args.password)
    _validate(new_password)

    await auth_service.reset_admin_password(new_password)

    print(t("auth.resetPassword.done"))
    print(t("auth.resetPassword.doneUsername", username=account.username))
    if generated:
        print(t("auth.resetPassword.donePassword", password=new_password))
        print(t("auth.resetPassword.generatedHint"))
    print(t("auth.resetPassword.sessionsHint"))
    return 0


def main(argv: list[str] | None = None) -> int:
    # 帮助与数据目录提示在连上数据库之前：只能看终端声明的语言，没声明用中文（原有行为）
    with use_locale(_terminal_locale() or "zh-Hans"):
        parser = argparse.ArgumentParser(
            prog="python -m movieclaw_api.reset_password",
            description=t("auth.resetPassword.description"),
            formatter_class=argparse.RawDescriptionHelpFormatter,
            epilog=(
                t("auth.resetPassword.examples") + "\n"
                "  docker exec -it movieclaw python -m movieclaw_api.reset_password\n"
                "  docker exec -it movieclaw python -m movieclaw_api.reset_password --show\n"
            ),
        )
        parser.add_argument("--show", action="store_true", help=t("auth.resetPassword.showHelp"))
        parser.add_argument("--password", help=t("auth.resetPassword.passwordHelp"))
        args = parser.parse_args(argv)

    # 只让警告及以上的日志露面：正常路径下的输出全部由 print 负责，
    # 面向的是不看日志的普通部署者
    logging.basicConfig(level=logging.WARNING, format="%(levelname)s %(message)s")
    return asyncio.run(_run(args))


if __name__ == "__main__":
    raise SystemExit(main())
