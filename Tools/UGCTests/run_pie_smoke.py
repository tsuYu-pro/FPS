#!/usr/bin/env python3
"""T3 验收驱动：UE 5.4 编辑器内 PIE 冒烟验收（7 项）。

做的事：
  1. 启动 UE 5.4 编辑器，带 `-ExecCmds="UGC.SmokeTestEnable"`（打开冒烟开关）
  2. 等 UEEditorMCP 的 TCP 服务（55558）就绪，清一次日志缓冲
  3. 通过 MCP `start_pie` 拉起 PIE；若已经处于 PIE 就复用
  4. 轮询 Saved/Logs/FPS.log，收集 `smoke_item_result` / `smoke_run_summary`
  5. MCP `stop_pie`，按 7/7 是否全通过决定退出码

为什么这么驱动：7 项验收里的 Delay/Interval 是真实时间调度、Trigger 与 Authoring↔Playtest
只能在真实 PIE 世界里跑；而这些验收的"是否通过"必须来自真实运行日志，不能靠静态推断。
MCP 的线协议见 Plugins/UEEditorMCP/Source/UEEditorMCP/Private/MCPServer.cpp：
4 字节大端长度前缀 + UTF-8 JSON，请求体 `{"type": "<action>", "params": {...}}`。

用法：
  python Tools/UGCTests/run_pie_smoke.py [--repo <路径>] [--timeout 600] [--no-launch]
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
PIE_ACTIONS = ("start_pie", "stop_pie", "get_pie_state", "is_ready", "clear_logs")


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


def launch_editor(repo: Path) -> subprocess.Popen:
    project = repo / "FPS.uproject"
    # UGC.SmokeTestEnable：打开「PIE BeginPlay 自动跑冒烟」开关。
    # UGC.SmokeTestOpenUGCLevel：先把编辑器切到 UGC 测试关卡 —— 冒烟驱动挂在 AUGCPlayerController 上，
    # 而编辑器默认打开的是登录地图（菜单 PC），不切关卡时 PIE 只会在登录地图里跑，冒烟永远不会开始
    # （2026-09-15 实测：PIE 起来 6 分钟没有任何 smoke_* 事件；之前那次 7/7 是先在游戏里选图开主机
    # 才进到 UGC 关卡的）。没有这个入口时 driver 无法独立复现验收。
    cmd = [
        EDITOR,
        str(project).replace("\\", "/"),
        '-ExecCmds=UGC.SmokeTestEnable, UGC.SmokeTestOpenUGCLevel',
    ]
    print(f"[t3] 启动编辑器: {' '.join(cmd)}")
    creationflags = 0
    if os.name == "nt":
        creationflags = subprocess.CREATE_NEW_PROCESS_GROUP
    return subprocess.Popen(cmd, cwd=str(repo), creationflags=creationflags)


def parse_smoke_log(log_path: Path, from_offset: int) -> tuple[list[dict], dict | None, int]:
    """从日志偏移处读新增内容，抽取冒烟结果。"""
    if not log_path.exists():
        return [], None, from_offset
    data = log_path.read_bytes()
    if len(data) < from_offset:
        from_offset = 0                      # 日志被轮转/截断
    chunk = data[from_offset:].decode("utf-8", errors="replace")
    items: list[dict] = []
    summary: dict | None = None
    for line in chunk.splitlines():
        if "event=smoke_item_result" in line:
            item_match = re.search(r'"item":(\d+)', line)
            ok_match = re.search(r'"ok":(true|false)', line)
            detail_match = re.search(r'"detail":"((?:[^"\\]|\\.)*)"', line)
            title_match = re.search(r'"title":"((?:[^"\\]|\\.)*)"', line)
            if item_match and ok_match:
                items.append({
                    "item": int(item_match.group(1)),
                    "ok": ok_match.group(1) == "true",
                    "detail": (detail_match.group(1) if detail_match else "").encode().decode("unicode_escape", errors="replace"),
                    "title": (title_match.group(1) if title_match else "").encode().decode("unicode_escape", errors="replace"),
                })
        elif "event=smoke_run_summary" in line:
            passed = re.search(r'"passed":(\d+)', line)
            failed = re.search(r'"failed":(\d+)', line)
            total = re.search(r'"total":(\d+)', line)
            if passed and failed:
                summary = {
                    "passed": int(passed.group(1)),
                    "failed": int(failed.group(1)),
                    "total": int(total.group(1)) if total else None,
                }
    return items, summary, from_offset + len(chunk.encode("utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=r"C:\Users\DearMe\Documents\Unreal Projects\FPS")
    parser.add_argument("--timeout", type=int, default=600, help="等待冒烟总结的秒数")
    parser.add_argument("--no-launch", action="store_true", help="编辑器已经在跑，直接驱动")
    args = parser.parse_args()

    repo = Path(args.repo)
    log_path = repo / "Saved" / "Logs" / "FPS.log"

    editor: subprocess.Popen | None = None
    if not args.no_launch:
        editor = launch_editor(repo)

    print("[t3] 等待 MCP 就绪（端口 55558）…")
    if not wait_for_mcp(time.time() + (args.timeout if editor else 120)):
        print("[t3] MCP 未就绪：编辑器可能启动失败（看 Saved/Logs/FPS.log 开头）")
        return 2

    try:
        print("[t3] 清空编辑器日志缓冲")
        try:
            mcp("clear_logs", timeout=30)
        except Exception as exc:                # 不是致命错误
            print(f"[t3] clear_logs 失败（忽略）: {exc}")

        offset = log_path.stat().st_size if log_path.exists() else 0

        state = {}
        try:
            state = mcp("get_pie_state", timeout=30)
        except Exception as exc:
            print(f"[t3] get_pie_state 失败（忽略）: {exc}")
        in_pie = json.dumps(state).lower().find('"is_in_pie":true') >= 0 or "in_pie" in json.dumps(state).lower() and "true" in json.dumps(state).lower()
        if in_pie:
            print("[t3] 已经在 PIE 中，复用当前会话")
        else:
            print("[t3] start_pie")
            response = mcp("start_pie", {"mode": "in_viewport"}, timeout=120)
            print(f"[t3] start_pie -> {json.dumps(response, ensure_ascii=False)[:200]}")

        print("[t3] 等待冒烟结果…")
        deadline = time.time() + args.timeout
        items: list[dict] = []
        summary: dict | None = None
        while time.time() < deadline:
            items, summary, offset = parse_smoke_log(log_path, offset)
            if summary:
                break
            time.sleep(3.0)

        print("\n[t3] ===== 冒烟结果 =====")
        for item in sorted(items, key=lambda entry: entry["item"]):
            flag = "PASS" if item["ok"] else "FAIL"
            print(f"  [{flag}] {item['item']}. {item['title'] or '(未命名)'} — {item['detail']}")
        if summary:
            total = summary.get("total") or (summary["passed"] + summary["failed"])
            print(f"\n[t3] 总结: passed={summary['passed']} failed={summary['failed']} total={total}")
        else:
            print("\n[t3] 超时：没有拿到 smoke_run_summary（冒烟没有跑完或没被触发）")

        try:
            mcp("stop_pie", timeout=60)
        except Exception as exc:
            print(f"[t3] stop_pie 失败（忽略）: {exc}")

        # 项数由脚本自己报（T16 之后是 8 项）：只要求「一条都不失败」且 passed 等于 total
        if summary and summary["failed"] == 0:
            total = summary.get("total") or summary["passed"]
            if summary["passed"] == total:
                print(f"[t3] {summary['passed']}/{total} 全部通过")
                return 0
        return 1
    finally:
        if editor is not None:
            print("[t3] 编辑器仍在运行（便于人工查看）；需要时手动关闭。")


if __name__ == "__main__":
    sys.exit(main())
