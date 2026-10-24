#!/usr/bin/env python3
"""配件基类验收驱动：编辑器 + PIE 里跑 FPS.AttachmentTest，从日志断言结果。

做的事：
  1. 启动 UE 5.4 编辑器，带
     -ExecCmds="UGC.SmokeTestOpenUGCLevel, FPS.AttachmentTestAuto <武器类路径>"
     （切到 UGC 测试关卡——PIE 会从这里复制世界、Play 时生成 BP_FPSPlayer；并挂上自动运行开关）
  2. 等 UEEditorMCP（55558）就绪，清日志缓冲
  3. MCP start_pie（若已在 PIE 则复用）
  4. 轮询 Saved/Logs/FPS.log，等 `event=attachment_test_summary`
  5. stop_pie，关闭本脚本启动的编辑器，按 result=PASS 决定退出码

用法：python Tools/UGCTests/run_attachment_test.py [--repo <路径>] [--timeout 300] [--no-launch] [--keep-editor]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path

EDITOR = r"C:\Program Files\Epic Games\UE_5.4\Engine\Binaries\Win64\UnrealEditor.exe"
MCP_PORT = 55558
DEFAULT_WEAPON_CLASS = "/Game/_FPS/Weapon/KA47/BP_Weapon_KA47.BP_Weapon_KA47_C"


def mcp(action: str, params: dict | None = None, timeout: float = 120.0) -> dict:
    """调一次 UEEditorMCP 动作，返回解析后的响应（失败抛异常）。"""
    with socket.create_connection(("127.0.0.1", MCP_PORT), timeout=timeout) as sock:
        sock.settimeout(timeout)
        payload = json.dumps({"type": action, "params": params or {}}).encode("utf-8")
        sock.sendall(struct.pack(">I", len(payload)) + payload)
        header = b""
        while len(header) < 4:
            chunk = sock.recv(4 - len(header))
            if not chunk:
                raise RuntimeError("MCP 连接被关闭（读长度前缀时）")
            header += chunk
        length = struct.unpack(">I", header)[0]
        body = b""
        while len(body) < length:
            chunk = sock.recv(min(65536, length - len(body)))
            if not chunk:
                raise RuntimeError("MCP 连接被关闭（读响应体时）")
            body += chunk
    return json.loads(body.decode("utf-8"))


def wait_for_mcp(deadline: float) -> bool:
    while time.time() < deadline:
        try:
            response = mcp("ping", timeout=5.0)
            if response.get("status") == "success":
                return True
        except Exception:
            time.sleep(2.0)
    return False


def launch_editor(repo: Path, weapon_class: str) -> subprocess.Popen:
    project = repo / "FPS.uproject"
    exec_cmds = f"UGC.SmokeTestOpenUGCLevel, FPS.AttachmentTestAuto {weapon_class}"
    cmd = [
        EDITOR,
        str(project).replace("\\", "/"),
        f"-ExecCmds={exec_cmds}",
    ]
    print(f"[attach-test] 启动编辑器: {' '.join(cmd)}")
    creationflags = 0
    if os.name == "nt":
        creationflags = subprocess.CREATE_NEW_PROCESS_GROUP
    return subprocess.Popen(cmd, cwd=str(repo), creationflags=creationflags)


def parse_attachment_log(log_path: Path, from_offset: int) -> tuple[list[str], dict | None, int]:
    """从日志偏移处读新增内容，抽取 [AttachmentTest] 行与总结事件。"""
    if not log_path.exists():
        return [], None, from_offset
    data = log_path.read_bytes()
    if len(data) < from_offset:
        from_offset = 0  # 日志被轮转/截断
    chunk = data[from_offset:].decode("utf-8", errors="replace")
    lines: list[str] = []
    summary: dict | None = None
    for line in chunk.splitlines():
        if "[AttachmentTest]" not in line:
            continue
        if "event=attachment_test_summary" in line:
            result = re.search(r"result=(\w+)", line)
            before = re.search(r"before=(\d+)", line)
            after_install = re.search(r"after_install=(\d+)", line)
            after_remove = re.search(r"after_remove=(\d+)", line)
            if result:
                summary = {
                    "result": result.group(1),
                    "before": int(before.group(1)) if before else None,
                    "after_install": int(after_install.group(1)) if after_install else None,
                    "after_remove": int(after_remove.group(1)) if after_remove else None,
                }
        lines.append(line)
    return lines, summary, from_offset + len(chunk.encode("utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=r"C:\Users\DearMe\Documents\Unreal Projects\FPS")
    parser.add_argument("--timeout", type=int, default=300, help="等待总结事件的秒数")
    parser.add_argument("--weapon-class", default=DEFAULT_WEAPON_CLASS, help="没有武器时用于生成调试武器的类路径")
    parser.add_argument("--no-launch", action="store_true", help="编辑器已经在跑，直接驱动")
    parser.add_argument("--keep-editor", action="store_true", help="跑完不关编辑器（默认关掉本脚本启动的那个）")
    args = parser.parse_args()

    repo = Path(args.repo)
    log_path = repo / "Saved" / "Logs" / "FPS.log"

    editor: subprocess.Popen | None = None
    if not args.no_launch:
        editor = launch_editor(repo, args.weapon_class)

    print("[attach-test] 等待 MCP 就绪（端口 55558）…")
    if not wait_for_mcp(time.time() + (args.timeout if editor else 120)):
        print("[attach-test] MCP 未就绪：编辑器可能启动失败（看 Saved/Logs/FPS.log 开头）")
        return 2

    exit_code = 1
    try:
        print("[attach-test] 清空编辑器日志缓冲")
        try:
            mcp("clear_logs", timeout=30)
        except Exception as exc:
            print(f"[attach-test] clear_logs 失败（忽略）: {exc}")

        offset = log_path.stat().st_size if log_path.exists() else 0

        state = {}
        try:
            state = mcp("get_pie_state", timeout=30)
        except Exception as exc:
            print(f"[attach-test] get_pie_state 失败（忽略）: {exc}")
        in_pie = '"is_in_pie":true' in json.dumps(state).lower()
        if in_pie:
            print("[attach-test] 已经在 PIE 中，复用当前会话")
        else:
            print("[attach-test] start_pie")
            response = mcp("start_pie", {"mode": "in_viewport"}, timeout=120)
            print(f"[attach-test] start_pie -> {json.dumps(response, ensure_ascii=False)[:200]}")

        print("[attach-test] 等待配件测试结果…")
        deadline = time.time() + args.timeout
        lines: list[str] = []
        summary: dict | None = None
        while time.time() < deadline:
            lines, summary, offset = parse_attachment_log(log_path, offset)
            if summary:
                break
            time.sleep(2.0)

        print("\n[attach-test] ===== 日志摘录 =====")
        for line in lines[-20:]:
            print(f"  {line.strip()}")
        if summary:
            print(
                f"\n[attach-test] 总结: result={summary['result']} "
                f"before={summary['before']} after_install={summary['after_install']} after_remove={summary['after_remove']}"
            )
            exit_code = 0 if summary["result"] == "PASS" else 1
        else:
            print("\n[attach-test] 超时：没有拿到 attachment_test_summary（测试没有跑完或没被触发）")

        try:
            mcp("stop_pie", timeout=60)
        except Exception as exc:
            print(f"[attach-test] stop_pie 失败（忽略）: {exc}")
    finally:
        if editor is not None and not args.keep_editor:
            print("[attach-test] 关闭编辑器进程")
            editor.terminate()
            try:
                editor.wait(timeout=30)
            except Exception:
                editor.kill()

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
