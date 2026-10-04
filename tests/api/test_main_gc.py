"""生产启动时冻结导入期对象，运行期循环引用仍须能够被正常回收。"""

import subprocess
import sys
from pathlib import Path
from textwrap import dedent


def test_startup_freezes_before_runtime_objects_and_keeps_gc_enabled():
    # 在子进程验证真实 GC 行为，避免冻结 pytest 自身的 fixture / 数据库对象。
    script = dedent("""
        import gc
        import weakref
        from types import SimpleNamespace
        from movieclaw_api import main

        main.get_settings = lambda: SimpleNamespace(
            log_level="INFO", log_dir="data/logs", log_retention_days=1,
            port=8000, host="127.0.0.1", reload=False,
        )
        main.configure_logging = lambda *args: None
        main.register_uvicorn_server = lambda server: None
        main.restart_exit_code = lambda: None

        frozen_before = gc.get_freeze_count()
        application = SimpleNamespace(routes=[])
        def create_app():
            assert gc.get_freeze_count() == frozen_before
            return application
        main.app = create_app

        def config(*args, **kwargs):
            assert gc.get_freeze_count() > frozen_before
            assert args[0] is application
            assert not kwargs.get("factory")
            return None

        class Server:
            def __init__(self, config):
                assert gc.get_freeze_count() > frozen_before

            def run(self):
                assert gc.isenabled()
                class RuntimeObject:
                    pass
                obj = RuntimeObject()
                obj.cycle = obj
                reference = weakref.ref(obj)
                del obj
                gc.collect()
                assert reference() is None, "运行期循环引用必须能被回收"

        main.uvicorn.Config = config
        main.uvicorn.Server = Server
        main.run()
    """)
    result = subprocess.run(
        [sys.executable, "-c", script],
        cwd=Path(__file__).resolve().parents[2],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
