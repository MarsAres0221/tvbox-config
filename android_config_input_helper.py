import argparse
import json
import re
import time
import xml.etree.ElementTree as ET

import uiautomator2 as u2


ADB_ENDPOINT = "127.0.0.1:16384"

COORDS = {
    "name": (545, 690),
    "url": (973, 690),
    "confirm": (1221, 680),
}


def parse_bounds(bounds):
    match = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds or "")
    if not match:
        return None
    x1, y1, x2, y2 = map(int, match.groups())
    return (x1 + x2) // 2, (y1 + y2) // 2


def xml_root(d):
    dump = d.dump_hierarchy()
    return ET.fromstring(dump.encode("utf-8") if isinstance(dump, str) else dump)


def click_text(d, text):
    root = xml_root(d)
    for node in root.iter():
        if node.get("text") != text:
            continue
        point = parse_bounds(node.get("bounds"))
        if point:
            d.click(*point)
            return True
    return False


def delete_all_lines(d):
    deleted = 0
    for _ in range(20):
        root = xml_root(d)
        buttons = root.findall(".//*[@resource-id='com.huawei.himovceie:id/tvDel']")
        if not buttons:
            return deleted
        point = parse_bounds(buttons[0].get("bounds"))
        if not point:
            return deleted
        d.click(*point)
        time.sleep(1)
        if not click_text(d, "确定"):
            d.click(853, 489)
        deleted += 1
        time.sleep(1)
    return deleted


def input_config(display_name, url):
    d = u2.connect(ADB_ENDPOINT)
    deleted = delete_all_lines(d)

    d.click(*COORDS["name"])
    time.sleep(1)
    d.clear_text()
    time.sleep(0.5)
    d.send_keys(display_name)
    time.sleep(1)

    d.click(*COORDS["url"])
    time.sleep(1)
    d.clear_text()
    time.sleep(0.5)
    d.send_keys(url)
    time.sleep(1)

    field = d(className="android.widget.EditText", instance=1)
    typed_url = field.get_text() if field.exists else ""
    if typed_url != url:
        return {
            "ok": False,
            "reason": f"URL 输入不完整 ({len(typed_url)}/{len(url)})",
        }

    d.click(*COORDS["confirm"])
    time.sleep(3)
    return {"ok": True, "reason": f"URL 输入完整，已清理 {deleted} 条旧线路"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    parser.add_argument("--url", required=True)
    args = parser.parse_args()
    result = input_config(args.name, args.url)
    print(json.dumps(result, ensure_ascii=True))


if __name__ == "__main__":
    main()
