#!/usr/bin/env python3
# encoding: utf-8
"""
三类设置动作：皮肤、方案、词典。

全部只写 .custom.yaml / 只读现有配置，绝不改动仓库自带的 yaml，
因此升级方案时用户的选择不会丢。
"""
import re
import subprocess
from pathlib import Path

from rime_config import (
    backup_once,
    parse_schema_list,
    parse_schema_meta,
    parse_scheme_block,
    parse_top_map,
    patch_insert,
    read_custom_scalar,
    read_lines,
    remove_key_block,
    set_yaml_scalar,
)
from rime_paths import find_scheme_source, find_tool, front_end_name


class RimeApp:
    def __init__(self, user_dir):
        self.user_dir = Path(user_dir)
        self.front = front_end_name(self.user_dir)
        self.custom = self.user_dir / (self.front + ".custom.yaml")

    # --- 皮肤 ---------------------------------------------------------------

    def skin_state(self):
        src = find_scheme_source(self.user_dir)
        schemes = parse_scheme_block(src)
        style = parse_top_map(src, "style")
        light = (read_custom_scalar(self.custom, "style/color_scheme")
                 or style.get("color_scheme"))
        dark = (read_custom_scalar(self.custom, "style/color_scheme_dark")
                or style.get("color_scheme_dark"))
        return {
            "source": str(src) if src else None,
            "custom": str(self.custom),
            "schemes": schemes,
            "current_light": light,
            "current_dark": dark,
            "style": style,
        }

    def skin_apply(self, light, dark):
        valid = {s["id"] for s in parse_scheme_block(find_scheme_source(self.user_dir))}
        for name in (light, dark):
            if name and name not in valid:
                raise ValueError("未知皮肤: %s" % name)
        backup_once(self.custom)
        if light:
            set_yaml_scalar(self.custom, "style/color_scheme", light)
        if dark:
            set_yaml_scalar(self.custom, "style/color_scheme_dark", dark)
        return {"written": str(self.custom)}

    # --- 方案 ---------------------------------------------------------------

    def schema_state(self):
        all_ids = parse_schema_list(self.user_dir / "default.yaml")
        # custom 里没写 schema_list（或读不到）时回落到 default.yaml 全量
        enabled = parse_schema_list(self.user_dir / "default.custom.yaml")
        if not enabled:
            enabled = list(all_ids)
        items = []
        for sid in all_ids:
            meta = parse_schema_meta(self.user_dir / (sid + ".schema.yaml"))
            items.append({
                "id": sid,
                "name": meta.get("name") or sid,
                "version": meta.get("version") or "",
                "enabled": sid in enabled,
            })
        return {
            "all": items,
            "enabled": enabled,
            "custom": str(self.user_dir / "default.custom.yaml"),
        }

    def schema_apply(self, ids):
        all_ids = parse_schema_list(self.user_dir / "default.yaml")
        for sid in ids:
            if sid not in all_ids:
                raise ValueError("未知方案: %s" % sid)
        if not ids:
            raise ValueError("至少要保留一个方案")

        custom = self.user_dir / "default.custom.yaml"
        backup_once(custom)

        # 就地替换已有的 schema_list 块。绝不能新起一个 patch: ——
        # YAML 同名键覆盖会让先写的内容全部失效。
        lines = remove_key_block(read_lines(custom), "schema_list")
        block = ["  schema_list:"]
        block += ["    - schema: %s" % sid for sid in ids]
        patch_insert(lines, block)
        custom.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return {"written": str(custom), "ids": ids}

    # --- 词典 ---------------------------------------------------------------

    def dict_state(self):
        dicts = [{"name": p.name, "path": str(p)}
                 for p in sorted(self.user_dir.glob("*.userdb"))]
        sync_dir = None
        inst = self.user_dir / "installation.yaml"
        if inst.is_file():
            m = re.search(r"^sync_dir\s*:\s*(.*)$",
                          inst.read_text(encoding="utf-8", errors="replace"), re.M)
            if m:
                sync_dir = m.group(1).strip().strip("\"'")
        tool = find_tool("rime_dict_manager")
        return {
            "dicts": dicts,
            "sync_dir": sync_dir,
            "tool": str(tool) if tool else None,
        }

    def dict_action(self, action, name=None):
        # 先校验动作，再找工具：参数写错时给出准确原因，
        # 而不是被「找不到 rime_dict_manager」掩盖。
        if action not in ("list", "sync", "backup"):
            raise ValueError("未知动作: %s" % action)
        if action == "backup" and not name:
            raise ValueError("需要指定词典名")

        tool = find_tool("rime_dict_manager")
        if not tool:
            raise ValueError(
                "找不到 rime_dict_manager。鼠须管正常安装时应位于 "
                "/Library/Input Methods/Squirrel.app/Contents/MacOS/"
            )
        if action == "list":
            args = [str(tool), "--list"]
        elif action == "sync":
            args = [str(tool), "--sync"]
        else:
            args = [str(tool), "--backup", name]

        # rime_dict_manager 的 user_data_dir 默认取当前目录，必须 cd 进去
        proc = subprocess.run(args, cwd=str(self.user_dir),
                              capture_output=True, text=True, timeout=180)
        return {
            "cmd": " ".join(args),
            "code": proc.returncode,
            "stdout": proc.stdout.strip(),
            "stderr": proc.stderr.strip(),
        }

    # --- 部署 ---------------------------------------------------------------

    def redeploy(self):
        d = find_tool("rime_deployer")
        if not d:
            return {"ok": False, "code": None,
                    "message": "找不到 rime_deployer，请用菜单栏「部署」"}
        proc = subprocess.run([str(d), "--build"], cwd=str(self.user_dir),
                              capture_output=True, text=True, timeout=600)
        return {
            "ok": proc.returncode == 0,
            "code": proc.returncode,
            "stdout": proc.stdout.strip(),
            "stderr": proc.stderr.strip(),
        }
