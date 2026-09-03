"""Agent 脚本执行器（python_exec 工具运行时）。

接收一段 Python 脚本文本，在当前解释器中 exec 执行（app 权限，与 shell_exec 同边界），
捕获 stdout/stderr/异常后以 JSON 字符串返回。原生层（Kotlin）负责超时保护。
"""

import io
import json
import traceback
from contextlib import redirect_stdout, redirect_stderr


def run_script(script):
    """执行一段脚本，返回 JSON 字符串。

    {"ok": bool, "stdout": str, "stderr": str, "error": str | None}
    """
    stdout, stderr = io.StringIO(), io.StringIO()
    ok, error = False, None
    try:
        with redirect_stdout(stdout), redirect_stderr(stderr):
            # 提供 __name__ 便于脚本内 if __name__ == "__main__" 判断；
            # 不注入 __builtins__ 以外的能力（app 权限即边界）。
            exec(script, {"__name__": "__main__"})
        ok = True
    except BaseException:
        error = traceback.format_exc()
    return json.dumps(
        {
            "ok": ok,
            "stdout": stdout.getvalue(),
            "stderr": stderr.getvalue(),
            "error": error,
        },
        ensure_ascii=False,
    )
