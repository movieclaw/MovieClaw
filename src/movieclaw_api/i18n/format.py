"""Dates in notification text follow its recipient's language and time zone."""

from datetime import date, datetime
from zoneinfo import ZoneInfo

from babel import Locale
from babel.dates import format_date, format_datetime

from movieclaw_api.i18n import current_locale, current_timezone, t


def month_day(value: date) -> str:
    return format_date(
        value,
        t("units.date.monthDayPattern"),
        locale=Locale.parse(current_locale.get(), sep="-"),
    )


def absolute_time(value: datetime) -> str:
    return format_datetime(
        value,
        t("units.date.absolutePattern"),
        tzinfo=ZoneInfo(current_timezone.get()),
        locale=Locale.parse(current_locale.get(), sep="-"),
    )
