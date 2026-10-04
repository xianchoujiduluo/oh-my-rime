#!/usr/bin/env python3
# encoding: utf-8
"""
Rime 用户目录与外部工具的定位。

各前端把用户目录放在不同位置，且我们还要找到一个能执行部署/同步的工具
（macOS 上是鼠须管应用包里的 rime_deployer / rime_dict_manager）。
"""
import os
import shutil
import sys
from pathlib import Path

# 鼠须管应用包可能的位置：系统级安装优先，其次是 /Applications
SQUIRREL_DIRS = [
    Path("/Library/Input Methods/Squirrel.app/Contents"),
    Path("/Applications/Squirrel.app/Contents"),
]


def candidate_user_dirs():
    home = Path.home()
    return [
        home / "Library/Rime",                       # macOS 鼠须管
        home / ".local/share/fcitx5/rime",           # Linux fcitx5
        home / ".config/ibus/rime",                  # Linux ibus
        home / ".config/fcitx/rime",
    ]


def detect_dir():
    """挑第一个真实存在的用户目录，都不存在时返回 macOS 默认值供报错提示。"""
    for d in candidate_user_dirs():
        if d.is_dir():
            return d
    return candidate_user_dirs()[0]


def find_scheme_source(user_dir):
    """找到含 preset_color_schemes 的皮肤预设文件。

    顺序：用户目录里的 squirrel.yaml / weasel.yaml
        → 应用包 SharedSupport（用户目录还没部署过时靠它兜底）
    """
    for name in ("squirrel.yaml", "weasel.yaml"):
        p = user_dir / name
        if p.is_file() and "preset_color_schemes:" in p.read_text(
                encoding="utf-8", errors="replace"):
            return p
    for base in SQUIRREL_DIRS:
        p = base / "SharedSupport/squirrel.yaml"
        if p.is_file():
            return p
    return None


def find_tool(name):
    """定位 rime 工具（rime_deployer / rime_dict_manager）。

    这两个可执行文件被鼠须管打在 Contents/MacOS/ 下
    （xcodeproj 里目标为 Executables），因此优先查应用包。
    """
    for base in SQUIRREL_DIRS:
        p = base / "MacOS" / name
        if p.is_file() and os.access(p, os.X_OK):
            return p
    found = shutil.which(name)
    return Path(found) if found else None


def front_end_name(user_dir):
    """判断前端是哪个，决定覆写文件叫 squirrel.custom.yaml 还是 weasel.custom.yaml。"""
    for name in ("squirrel.yaml", "weasel.yaml"):
        if (user_dir / name).is_file():
            return name.split(".")[0]
    return "squirrel" if sys.platform == "darwin" else "weasel"
