#!/usr/bin/env python3
"""从线上抓一份真实的 v2 library 响应，原样存成解码测试的契约基准。

为什么要有这个脚本：fixture 一旦变成「手抄的」，它就不再是契约，
而是某个人的记忆。线上改了字段，手抄的 fixture 不会跟着变，
测试照样绿，客户端照样在真机上炸。所以 fixture 必须能被一条命令重新生成。

用法（在 ios2/ 下）：
    python Tools/fetch_fixture.py [共享码]
默认共享码取自环境变量 CLIPNOTE_CODE，再退回 E2ZVITFINI。
"""

import json
import os
import pathlib
import sys
import urllib.request

BASE = os.environ.get("CLIPNOTE_BASE", "https://clipnote.app.workbuddy.host")
OUT = pathlib.Path("Tests/ClipNote2Tests/Fixtures/library-real.json")


def main() -> int:
    code = (sys.argv[1] if len(sys.argv) > 1 else os.environ.get("CLIPNOTE_CODE", "")) or "E2ZVITFINI"

    # 网关要求 sharecode，服务端要求 code，两个都要带
    url = f"{BASE}/api/v2/library?sharecode={code}&code={code}"

    # 显式禁用系统代理：本机代理会让这条 TLS 握手失败
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    request = urllib.request.Request(url)
    request.add_header("Accept", "application/json")

    with opener.open(request, timeout=30) as response:
        content_type = response.headers.get("Content-Type", "")
        raw = response.read()

    if "json" not in content_type.lower():
        print(f"不是 JSON（Content-Type={content_type!r}），线上大概没部署 v2", file=sys.stderr)
        return 1

    # 原样保存，不做任何美化以外的加工：这份文件的意义就是「服务端到底返回了什么」
    data = json.loads(raw.decode("utf-8"))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(f"写入 {OUT}")
    print(f"  apiVersion : {data.get('apiVersion')}")
    print(f"  version    : {data.get('libraryVersion')}")
    print(f"  count      : {data.get('count')}")
    print(f"  bytes      : {OUT.stat().st_size}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
