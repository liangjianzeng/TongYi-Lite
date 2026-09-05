"""Agent 脚本执行器（python_exec 工具运行时）。

接收一段 Python 脚本文本，在当前解释器中 exec 执行（app 权限，与 shell_exec 同边界），
捕获 stdout/stderr/异常后以 JSON 字符串返回。原生层（Kotlin）负责超时保护。

stdin 契约（对齐 DSH：stdin 是"一次性喂入并关闭"的批次输入，不是交互式）：
- [stdin_input] 提供时，写入 sys.stdin，脚本内的 input() 可正常读到对应行；
- 未提供时 sys.stdin 置为空缓冲，input() 会立即收到 EOF（模型由此判断无输入）。
"""

import io
import json
import sys
import traceback
from contextlib import redirect_stdout, redirect_stderr


def run_script(script, stdin_input=None):
    """执行一段脚本，返回 JSON 字符串。

    {"ok": bool, "stdout": str, "stderr": str, "error": str | None}
    """
    stdout, stderr = io.StringIO(), io.StringIO()
    ok, error = False, None
    # 把模型喂的 stdin 接成可读缓冲：有输入时 input() 正常返回；
    # 无输入时为空缓冲，input() 收到 EOF，错误会透传给模型而非静默崩溃。
    fake_stdin = io.StringIO(stdin_input if isinstance(stdin_input, str) else "")
    real_stdin = sys.stdin
    try:
        sys.stdin = fake_stdin
        with redirect_stdout(stdout), redirect_stderr(stderr):
            # 提供 __name__ 便于脚本内 if __name__ == "__main__" 判断；
            # 不注入 __builtins__ 以外的能力（app 权限即边界）。
            exec(script, {"__name__": "__main__"})
        ok = True
    except BaseException:
        error = traceback.format_exc()
    finally:
        sys.stdin = real_stdin
    return json.dumps(
        {
            "ok": ok,
            "stdout": stdout.getvalue(),
            "stderr": stderr.getvalue(),
            "error": error,
        },
        ensure_ascii=False,
    )
