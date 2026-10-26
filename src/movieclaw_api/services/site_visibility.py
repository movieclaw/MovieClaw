"""成员站点可用性判定的单点收口（docs/design/member-management.md §3.6 末）。

与库可见性（services.library.access）同构的三件套第二应用：判定只在
这里做，消费面（交互式搜索的站点枚举）不自行拼条件。

命名说明：站点客户端连接管理叫 ``site_access``（进程级共享会话），
本模块管的是"**谁**能用哪些站"，取名 visibility 与之区分。

约定：
- 返回 ``None`` 表示**不受限**（超管、PAT/Agent、all_sites 成员）；
- 站点白名单作用于**成员发起的交互式动作**：搜索时只枚举可用站点，提交下载
  （一键下载、手动选种）时用 :func:`assert_site_usable` 再校验一次——请求里的
  ``site_id`` 是客户端给的，只在搜索端收窄挡不住绕过前端直接构造的提交；
- 订阅链路的被动匹配与
  缺口搜索是系统行为，不经过本判定（资源共享原则：下载成果全家共享，
  不因发起人的站点受限而缩小搜索面）。
"""

from __future__ import annotations

from urllib.parse import urlsplit

from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.exceptions import ForbiddenException
from movieclaw_api.services.auth import Principal
from movieclaw_db.repositories.member_repo import MemberRepository


async def usable_site_ids(session: AsyncSession, principal: Principal) -> set[str] | None:
    """请求主体可用的站点 id 集合；None = 不受限（管理员语义）。"""
    if principal.is_admin or principal.member is None:
        return None
    member = principal.member
    if member.all_sites:
        return None
    return set(await MemberRepository(session).get_site_ids(member.id))


async def assert_site_usable(session: AsyncSession, principal: Principal, site_id: str) -> None:
    """断言请求主体可以使用这个站点；成员白名单外的站点一律 403。"""
    allowed = await usable_site_ids(session, principal)
    if allowed is not None and site_id not in allowed:
        raise ForbiddenException(message_key="errors.sites.downloadNotAllowed")


def _host_of(url: str | None) -> str:
    return (urlsplit(url).hostname or "").lower() if url else ""


#: 常见的二级公共后缀（如 example.co.uk 的 co.uk）：主域名要多取一段
_SECOND_LEVEL_SUFFIXES = {"co", "com", "net", "org", "edu", "gov", "ac"}


def _site_domain(host: str) -> str:
    """站点的主域名：pt.example.com → example.com，pt.example.co.uk → example.co.uk。

    同一站点的 API、网页与下载常分属不同子域名（pt. / www. / download.），按主域名
    比对才不误伤；伪装成 ``example.com.evil.test`` 的主域名是 evil.test，照样拦住。
    """
    labels = host.split(".")
    take = 3 if len(labels) >= 3 and labels[-2] in _SECOND_LEVEL_SUFFIXES else 2
    return ".".join(labels[-take:])


async def assert_download_url_on_site(
    principal: Principal, site_id: str, download_url: str | None
) -> None:
    """断言成员提交的下载链接属于这个站点本身。

    取种时站点客户端会带上该站的登录态（Cookie / API Key 是客户端级默认值，
    不按目标域名区分）。``download_url`` 由客户端提交，成员若把它换成任意外部
    地址，服务端就会替他把站点凭据发过去——凭据泄露意味着 PT 账号被封，是成员
    体系里明确的高危面（member-management.md §1）。

    放行：相对路径与不带协议的种子 ID（如 M-Team）——它们只会拼到站点自己的
    域名上；绝对地址的主机必须与站点 API 域名或网页域名同属一个主域名。
    超管不校验：超管本就持有全部站点凭据，行为与之前保持一致。
    """
    if principal.is_admin or not download_url:
        return
    parts = urlsplit(download_url.strip())
    if not parts.scheme and not parts.netloc:
        return
    from movieclaw_api.services.site_access import SiteUnavailableError, get_site_access

    try:
        site = await get_site_access().get(site_id)
    except SiteUnavailableError:
        # 站点不可用由随后的取种步骤给出可读的中文错误，这里不抢着报
        return
    host = (parts.hostname or "").lower()
    domains = {
        _site_domain(h)
        for h in (_host_of(site.base_url), _host_of(getattr(site, "web_base_url", None)))
        if h
    }
    if host and any(host == d or host.endswith("." + d) for d in domains):
        return
    raise ForbiddenException(message_key="errors.sites.downloadLinkMismatch")
