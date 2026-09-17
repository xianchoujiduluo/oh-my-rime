#!/usr/bin/env python3
# encoding: utf-8
"""
打包 oh-my-rime 为可分发的 zip。

用法（仓库根目录）:
    python3 tools/pack.py                 # 输出 dist/oh-my-rime.zip
    python3 tools/pack.py -o /tmp/a.zip   # 指定输出路径

设计要点:
  * 只依赖标准库，无需 `zip` 命令 —— 因此 GitHub Actions 与本地可跑同一份代码。
  * 排除 .git 以及所有“点文件/点目录”（.github/、.ide/ 等），
    注意不能沿用 `find ! -name ".*"`：那只挡文件名，挡不住点目录。
  * 包内附带 manifest.txt，记录本包包含哪些文件。
    install.sh / install.ps1 依赖它实现“精确卸载”。
"""
import argparse
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = "manifest.txt"


def collect(root, output=None):
    """返回仓库内应当打包的相对路径列表（已排序、已剔除点文件/点目录）。

    output 为输出 zip 的路径：必须排除，否则重复打包会把上一次的产物
    包进去，导致体积雪崩式增长。
    """
    out_abs = os.path.abspath(output) if output else None

    # 若输出文件位于仓库内，剪掉它所在的最顶层目录，避免重复扫描大目录
    prune_top = None
    if out_abs and out_abs.startswith(os.path.abspath(root) + os.sep):
        rel_out = os.path.relpath(out_abs, root)
        first = rel_out.split(os.sep)[0]
        if first not in (os.curdir, os.pardir):
            prune_top = first

    files = []
    for dirpath, dirnames, filenames in os.walk(root):
        # 原地修改 dirnames 以剪枝：跳过 .git、一切点目录、以及输出目录
        dirnames[:] = sorted(
            d for d in dirnames
            if not d.startswith(".")
            and not (prune_top and os.path.relpath(os.path.join(dirpath, d), root) == prune_top)
        )

        for name in sorted(filenames):
            if name.startswith("."):
                continue
            full = os.path.join(dirpath, name)
            if out_abs and os.path.abspath(full) == out_abs:
                continue  # 绝不打包自己
            rel = os.path.relpath(full, root)
            if rel == MANIFEST:
                continue
            files.append(rel.replace(os.sep, "/"))
    return sorted(files)


def build(zip_path, root=ROOT):
    files = collect(root, output=zip_path)
    if not files:
        print("错误: 没有可打包的文件", file=sys.stderr)
        return 1

    os.makedirs(os.path.dirname(os.path.abspath(zip_path)), exist_ok=True)
    manifest_text = "\n".join(files) + "\n"

    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr(MANIFEST, manifest_text)
        for rel in files:
            zf.write(os.path.join(root, rel), rel)

    size_mb = os.path.getsize(zip_path) / 1048576
    print(f"✅ 已生成 {zip_path}")
    print(f"   文件数: {len(files)}（另有 {MANIFEST}）")
    print(f"   大小:   {size_mb:.1f} MB")
    return 0


def main():
    ap = argparse.ArgumentParser(description="打包 oh-my-rime")
    ap.add_argument("-o", "--output", default=os.path.join(ROOT, "dist", "oh-my-rime.zip"),
                    help="输出 zip 路径（默认 dist/oh-my-rime.zip）")
    args = ap.parse_args()
    sys.exit(build(args.output))


if __name__ == "__main__":
    main()
