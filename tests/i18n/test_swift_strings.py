import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts/i18n"))

from swift_strings import literals  # noqa: E402


def texts(source):
    return [literal.text for literal in literals(source)]


def test_nested_interpolation_literals_are_reported_separately():
    source = 'Text("\\(a ? "已下载" : "正在下载") · \\(b)")'
    assert texts(source) == ["已下载", "正在下载", " · "]


def test_comments_and_raw_strings():
    source = '// "注释"\nlet a = #"原始 "引号" \\(x)"#\n/* "块" */ let b = "x"'
    assert texts(source) == ['原始 "引号" \\(x)', "x"]


def test_multiline_string_and_escapes():
    source = 'let s = """\n第一行 \\(n) 集\n"""\nlet t = "a\\"b"'
    assert texts(source) == ["\n第一行  集\n", 'a\\"b']


def test_parentheses_inside_interpolation():
    source = 'let s = "共 \\(f(g(1), "单位")) 项"'
    assert texts(source) == ["单位", "共  项"]
