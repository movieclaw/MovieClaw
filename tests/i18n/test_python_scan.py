import ast
import importlib.util
import re
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "i18n_check", Path(__file__).resolve().parents[2] / "scripts/i18n/check.py"
)
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)

HAN = re.compile(r"[㐀-鿿]")


def counted(source):
    tree = ast.parse(source)
    skipped = check.excluded_nodes(tree)
    return [
        node.value
        for node in ast.walk(tree)
        if isinstance(node, ast.Constant)
        and isinstance(node.value, str)
        and HAN.search(node.value)
        and id(node) not in skipped
    ]


def test_openapi_documentation_is_not_interface_text():
    source = """
name: str = Field(description="库的展示名")
@router.get("/x", summary="列出库", description="说明")
def route(): ...
raise BadRequestException("库名重复")
"""
    assert counted(source) == ["库名重复"]


def test_chinese_fallback_beside_its_key_is_migrated():
    source = """
register_task("a", title="清理历史", title_key="settings.x.title", description="删除旧记录")
raise JobRetry("稍后重试", message_key="library.x.retry")
raise JobRetry("仍未迁移")
actions = [{"label": "重试", "label_key": "activity.jobs.retry"}, {"label": "配置模型"}]
rows = [{"title": f"任务 {n}", "_title_ref": ref}, {"label": "回收", "label_ref": ref}]
"""
    assert sorted(counted(source)) == ["仍未迁移", "删除旧记录", "配置模型"]


def test_bare_strings_logs_and_regex_patterns_are_not_interface_text():
    source = '''
TIMEOUT = 5
"""单个参与方预览的时限（秒）。"""
logger.info("扫描完成：%s", path)
SEASON = re.compile(r"第\\s*(\\d+)\\s*季")
label = "未知规格"
'''
    assert counted(source) == ["未知规格"]
