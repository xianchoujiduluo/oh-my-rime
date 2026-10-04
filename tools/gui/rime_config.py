#!/usr/bin/env python3
# encoding: utf-8
"""
Rime 配置文件的「最小可用」YAML 读写。

为什么不引入 PyYAML：依赖越少越不容易在别人机器上炸，而这里要处理的
结构非常窄 —— preset_color_schemes（map of map of 标量）、style（map of 标量）、
schema_list（list of map）。手工解析还额外带来一个好处：能保留「哪一行是哪个键」，
从而做到精确改写而不是整份重写。

写配置的核心约定：**绝不在 .custom.yaml 里造出第二个 patch: 键**。
YAML 中同名键后者覆盖前者，多出来的那个会静默吃掉先前所有设置。
"""
import re
import shutil
import time


def strip_comment_and_quotes(raw):
    """去掉行尾注释与包裹引号。引号内的 # 不算注释。"""
    out = []
    quote = ""
    for ch in raw:
        if quote:
            out.append(ch)
            if ch == quote:
                quote = ""
        elif ch in "\"'":
            quote = ch
            out.append(ch)
        elif ch == "#":
            break
        else:
            out.append(ch)
    text = "".join(out).strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        text = text[1:-1]
    return text


def _lines_of(path):
    if not path or not path.is_file():
        return []
    return path.read_text(encoding="utf-8", errors="replace").splitlines()


def parse_scheme_block(path):
    """解析 preset_color_schemes，返回 [{"id":..,"props":{...}}, ...]（保持文件顺序）。

    用「缩进层级」而非固定列数判断，上游把缩进从 2 空格改成 4 空格也不会失效。
    """
    schemes = []
    in_block = False
    block_indent = 0
    scheme_indent = 0
    cur = None

    for line in _lines_of(path):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        stripped = line.strip()

        if not in_block:
            if re.match(r"^preset_color_schemes\s*:", stripped):
                in_block = True
                block_indent = indent
            continue
        if indent <= block_indent and not stripped.startswith("-"):
            break

        m = re.match(r"^([A-Za-z0-9_.\-]+)\s*:\s*(.*)$", stripped)
        if not m:
            continue
        key, value = m.group(1), m.group(2)

        if scheme_indent == 0:
            scheme_indent = indent
        if indent == scheme_indent:
            cur = {"id": key, "props": {}}
            schemes.append(cur)
            if value:
                cur["props"][key] = strip_comment_and_quotes(value)
        elif cur is not None and indent > scheme_indent:
            cur["props"][key] = strip_comment_and_quotes(value)

    return schemes


def parse_top_map(path, top_key):
    """读取顶层某个 map（如 style:）下的标量键值。"""
    result = {}
    in_block = False
    block_indent = 0

    for line in _lines_of(path):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        stripped = line.strip()

        if not in_block:
            if re.match(r"^%s\s*:" % re.escape(top_key), stripped):
                in_block = True
                block_indent = indent
            continue
        if indent <= block_indent:
            break
        m = re.match(r"^([A-Za-z0-9_.\-]+)\s*:\s*(.*)$", stripped)
        if m:
            result[m.group(1)] = strip_comment_and_quotes(m.group(2))
    return result


def parse_schema_list(path):
    """读取 schema_list: 下的 [{schema: xxx}, ...]。"""
    schemas = []
    in_block = False
    block_indent = 0

    for line in _lines_of(path):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        stripped = line.strip()

        if not in_block:
            if re.match(r"^schema_list\s*:\s*$", stripped):
                in_block = True
                block_indent = indent
            continue
        if indent <= block_indent:
            break
        m = re.search(r"schema\s*:\s*([A-Za-z0-9_.\-]+)", stripped)
        if m:
            schemas.append(m.group(1))
    return schemas


def parse_schema_meta(path):
    """读取 *.schema.yaml 里的 schema_id / name / version。"""
    meta = {}
    in_schema = False
    schema_indent = 0

    for line in _lines_of(path):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        stripped = line.strip()

        if not in_schema:
            if re.match(r"^schema\s*:\s*$", stripped):
                in_schema = True
                schema_indent = indent
            continue
        if indent <= schema_indent:
            break
        m = re.match(r"^([a-z_]+)\s*:\s*(.*)$", stripped)
        if m:
            meta[m.group(1)] = strip_comment_and_quotes(m.group(2))
    return meta


def backup_once(path):
    """改文件前留一份带时间戳的备份，用户可随时回滚。"""
    if path.is_file():
        stamp = time.strftime("%Y%m%d-%H%M%S")
        shutil.copy2(path, path.with_name(path.name + ".bak-" + stamp))


def remove_key_block(lines, key):
    """删掉 key: 行及其所有更深的缩进行（即整个子块）。

    patch 里的键可能是标量（style/font_point: 18），也可能是嵌套块
    （schema_list:\\n  - schema: x），两种都要能整块摘干净。
    """
    pat = re.compile(r"^([ \t]*)(?:%s)[ \t]*:" % re.escape(key))
    out = []
    i = 0
    while i < len(lines):
        m = pat.match(lines[i])
        if not m:
            out.append(lines[i])
            i += 1
            continue
        base = len(m.group(1))
        i += 1
        while i < len(lines):
            ln = lines[i]
            if not ln.strip():
                i += 1
                continue
            if len(ln) - len(ln.lstrip()) <= base:
                break
            i += 1
    return out


def ensure_patch(lines):
    """保证存在唯一的 patch: 行，返回其下标。"""
    for i, ln in enumerate(lines):
        if re.match(r"^patch\s*:", ln):
            return i
    lines.insert(0, "patch:")
    return 0


def patch_insert(lines, new_lines):
    """把若干行插到 patch: 块首（紧跟 patch: 之后）。"""
    idx = ensure_patch(lines)
    lines[idx + 1:idx + 1] = new_lines
    return lines


def read_lines(custom):
    return _lines_of(custom)


def set_yaml_scalar(custom, key, value):
    """在 .custom.yaml 的 patch: 下设置扁平键，保留其余所有内容。

    Rime 的 patch 支持 `style/color_scheme: x` 这种斜杠扁平写法，
    因此用「按键整行替换」而不是构造嵌套结构，改动面最小。
    """
    lines = remove_key_block(read_lines(custom), key)
    patch_insert(lines, ["  %s: %s" % (key, value)])
    custom.write_text("\n".join(lines) + "\n", encoding="utf-8")


def read_custom_scalar(custom, key):
    """从 .custom.yaml 读取某个扁平键的值。"""
    pat = re.compile(r"^[ \t]*%s[ \t]*:[ \t]*(.*)$" % re.escape(key))
    for ln in read_lines(custom):
        m = pat.match(ln)
        if m:
            v = strip_comment_and_quotes(m.group(1))
            if v:
                return v
    return None
