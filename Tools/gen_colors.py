"""生成 Assets.xcassets 里的颜色 Token。

颜色若需调整，改下面的 TOKENS 再重跑本脚本；
不要手改 Contents.json —— 它只是生成物。

用法（在 ios2/ 目录下）：
    python Tools/gen_colors.py
"""

import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1] / "Sources" / "ClipNote2" / "Assets.xcassets"

# 名称: (浅色 hex, 浅色 alpha, 深色 hex, 深色 alpha)
TOKENS = {
    "bg":           ("FAFAF8", 1.00, "0B0B0D", 1.00),
    "card":         ("FFFFFF", 1.00, "16161A", 1.00),
    "card2":        ("F3F2EF", 1.00, "1E1E23", 1.00),
    "card3":        ("E9E7E2", 1.00, "28282E", 1.00),
    "ink":          ("131210", 1.00, "F6F4EF", 1.00),
    "ink2":         ("454239", 1.00, "BEB9AF", 1.00),
    "ink3":         ("6B6762", 1.00, "918B80", 1.00),
    "brand":        ("1F4FE0", 1.00, "6B8CFF", 1.00),
    "brandPress":   ("173BAE", 1.00, "4C6EF5", 1.00),
    "brandSoft":    ("1F4FE0", 0.10, "6B8CFF", 0.15),
    "green":        ("0E7A54", 1.00, "4ADE9B", 1.00),
    "greenSoft":    ("0E7A54", 0.10, "4ADE9B", 0.14),
    "red":          ("C4282E", 1.00, "FF7A82", 1.00),
    "hairline":     ("131210", 0.14, "FFFFFF", 0.12),
    "hairlineSoft": ("131210", 0.075, "FFFFFF", 0.07),
}


def components(hex6, alpha):
    return {
        "alpha": f"{alpha:.3f}",
        "blue": "0x" + hex6[4:6],
        "green": "0x" + hex6[2:4],
        "red": "0x" + hex6[0:2],
    }


def entry(hex6, alpha, dark=False):
    item = {
        "color": {"color-space": "srgb", "components": components(hex6, alpha)},
        "idiom": "universal",
    }
    if dark:
        item["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
    return item


def main():
    ROOT.mkdir(parents=True, exist_ok=True)
    (ROOT / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
        encoding="utf-8",
    )

    for name, (lt, la, dt, da) in TOKENS.items():
        folder = ROOT / f"{name}.colorset"
        folder.mkdir(parents=True, exist_ok=True)
        payload = {
            "colors": [entry(lt, la), entry(dt, da, dark=True)],
            "info": {"author": "xcode", "version": 1},
        }
        (folder / "Contents.json").write_text(
            json.dumps(payload, indent=2) + "\n", encoding="utf-8"
        )

    print(f"生成 {len(TOKENS)} 个 colorset -> {ROOT}")


if __name__ == "__main__":
    main()
