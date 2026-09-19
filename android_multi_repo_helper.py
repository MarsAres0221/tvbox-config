import argparse
import json
import re
import time
import xml.etree.ElementTree as ET
from pathlib import Path

import uiautomator2 as u2


APP_PACKAGE = "com.huawei.himovceie"
ADB_ENDPOINT = "127.0.0.1:16384"

COORDS = {
    "settings": (1485, 207),
    "config_addr": (537, 68),
    "name": (545, 690),
    "url": (973, 690),
    "confirm": (1221, 680),
}

TAB_KEYWORDS = ["热门电影", "热播剧集", "热门动漫", "热播综艺", "电影筛选", "电视筛选"]
HOME_KEYWORDS = ["历史", "直播", "搜索"]
HOME_ACTION_TEXTS = ["配置", "线路", "网盘", "收藏", "推送", "设置"]
IGNORED_SUBLINE_TEXTS = {"确定", "取消", "推送链接", "配置地址"}
IGNORED_SUBLINE_TEXTS.update(HOME_KEYWORDS)
IGNORED_SUBLINE_TEXTS.update(HOME_ACTION_TEXTS)
IGNORED_SUBLINE_TEXTS.update(TAB_KEYWORDS)


def parse_bounds(bounds):
    match = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds or "")
    if not match:
        return None
    x1, y1, x2, y2 = map(int, match.groups())
    return (x1 + x2) // 2, (y1 + y2) // 2


def xml_root(d):
    dump = d.dump_hierarchy()
    return ET.fromstring(dump.encode("utf-8") if isinstance(dump, str) else dump)


def dump_text(d):
    return d.dump_hierarchy()


def has_tab_bar(d):
    dump = dump_text(d)
    return any(keyword in dump for keyword in TAB_KEYWORDS)


def is_on_homepage(d):
    dump = dump_text(d)
    has_home_nav = all(keyword in dump for keyword in HOME_KEYWORDS)
    not_in_dialog = "配置地址" not in dump
    return has_home_nav and not_in_dialog


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


def dismiss_error_dialog(d):
    dump = dump_text(d)
    if "拉取配置失败" not in dump and "failed to connect" not in dump:
        return False
    if click_text(d, "取消"):
        time.sleep(2)
        return True
    return False


def dismiss_confirm_dialog(d):
    if click_text(d, "确定"):
        time.sleep(1)
        return True
    # Fallback for the delete confirmation dialog on 1600x900 landscape.
    d.click(853, 489)
    time.sleep(1)
    return True


def smart_back(d, max_attempts=2):
    for _ in range(max_attempts):
        if is_on_homepage(d):
            return True
        d.press("back")
        time.sleep(2)
    return is_on_homepage(d)


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
        dismiss_confirm_dialog(d)
        deleted += 1
        time.sleep(1)
    return deleted


def add_line(d, display_name, url):
    # 输入名称：使用 setText 绕过输入法
    name_field = d(className="android.widget.EditText", instance=0)
    name_field.click()
    time.sleep(0.5)
    name_field.set_text(display_name)
    time.sleep(0.5)

    # 输入 URL：使用 setText 绕过输入法
    url_field = d(className="android.widget.EditText", instance=1)
    url_field.click()
    time.sleep(0.5)
    url_field.set_text(url)
    time.sleep(0.5)

    typed_url = url_field.get_text() if url_field.exists else ""
    if typed_url != url:
        return False, f"URL 输入不完整 ({len(typed_url)}/{len(url)})"

    d.click(*COORDS["confirm"])
    for _ in range(45):
        time.sleep(1)
        dump = dump_text(d)
        if "推送链接" not in dump and "配置地址" not in dump:
            break
        if "com.huawei.himovceie:id/tvName" in dump and "推送链接" not in dump:
            break
        if all(keyword in dump for keyword in HOME_KEYWORDS):
            break
    return True, "URL 输入完整"


def open_added_line(d):
    root = xml_root(d)
    names = root.findall(".//*[@resource-id='com.huawei.himovceie:id/tvName']")
    if not names:
        return False
    point = parse_bounds(names[0].get("bounds"))
    if not point:
        return False
    d.click(*point)
    time.sleep(3)
    return True


def find_sub_lines(d):
    root = xml_root(d)
    options = []
    for node in root.iter():
        if node.get("class") != "android.widget.TextView":
            continue
        if node.get("clickable") != "true":
            continue
        text = (node.get("text") or "").strip()
        if not text or text in IGNORED_SUBLINE_TEXTS:
            continue
        point = parse_bounds(node.get("bounds"))
        if point:
            options.append({"text": text, "point": point})
    return options


def scroll_sub_lines_to_top(d):
    for _ in range(4):
        d.swipe(800, 320, 800, 720, 0.15)
        time.sleep(0.4)


def ensure_app(d):
    if is_on_homepage(d):
        return
    for _ in range(3):
        d.press("back")
        time.sleep(2)
        if is_on_homepage(d):
            return
    d.app_start(APP_PACKAGE)
    time.sleep(10)
    dismiss_error_dialog(d)
    smart_back(d, 2)
    time.sleep(2)


def test_multi_repo(display_name, url, screenshot_path, max_sub_lines):
    d = u2.connect(ADB_ENDPOINT)
    ensure_app(d)

    d.click(*COORDS["settings"])
    time.sleep(2)
    d.click(*COORDS["config_addr"])
    time.sleep(2)

    deleted = delete_all_lines(d)

    ok, input_reason = add_line(d, display_name, url)
    if not ok:
        d.screenshot(screenshot_path)
        return {
            "status": "Fail",
            "reason": input_reason,
            "labelCount": 0,
            "deleted": deleted,
            "subLine": "",
        }

    if is_on_homepage(d) and has_tab_bar(d):
        d.screenshot(screenshot_path)
        return {
            "status": "Pass",
            "reason": "多仓线路直接加载成功",
            "labelCount": 1,
            "deleted": deleted,
            "subLine": "",
        }

    if not open_added_line(d):
        d.screenshot(screenshot_path)
        return {
            "status": "Fail",
            "reason": "未找到刚添加的多仓线路",
            "labelCount": 0,
            "deleted": deleted,
            "subLine": "",
        }

    if is_on_homepage(d) and has_tab_bar(d):
        d.screenshot(screenshot_path)
        return {
            "status": "Pass",
            "reason": "多仓线路点选后直接加载成功",
            "labelCount": 1,
            "deleted": deleted,
            "subLine": "",
        }

    if "选择线路" not in dump_text(d):
        d.screenshot(screenshot_path)
        return {
            "status": "Fail",
            "reason": "未出现选择线路对话框",
            "labelCount": 0,
            "deleted": deleted,
            "subLine": "",
        }

    scroll_sub_lines_to_top(d)
    options = find_sub_lines(d)
    if not options:
        d.screenshot(screenshot_path)
        return {
            "status": "Fail",
            "reason": "未找到子线路选项",
            "labelCount": 0,
            "deleted": deleted,
            "subLine": "",
        }

    tried = []
    for option in options[:max_sub_lines]:
        tried.append(option["text"])
        d.click(*option["point"])
        time.sleep(30)
        dismiss_error_dialog(d)
        smart_back(d, 2)
        d.screenshot(screenshot_path)

        if has_tab_bar(d):
            return {
                "status": "Pass",
                "reason": f"多仓子线路可用: {option['text']}",
                "labelCount": 1,
                "deleted": deleted,
                "subLine": option["text"],
            }

        # Reopen the sub-line selector before trying the next option.
        d.click(*COORDS["settings"])
        time.sleep(2)
        d.click(*COORDS["config_addr"])
        time.sleep(2)
        if not open_added_line(d):
            break
        scroll_sub_lines_to_top(d)
        options = find_sub_lines(d)

    d.screenshot(screenshot_path)
    return {
        "status": "Fail",
        "reason": "多仓子线路未加载标签: " + ", ".join(tried),
        "labelCount": 0,
        "deleted": deleted,
        "subLine": "",
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--screenshot", required=True)
    parser.add_argument("--max-sub-lines", type=int, default=3)
    args = parser.parse_args()

    Path(args.screenshot).parent.mkdir(parents=True, exist_ok=True)
    result = test_multi_repo(args.name, args.url, args.screenshot, args.max_sub_lines)
    print(json.dumps(result, ensure_ascii=True))


if __name__ == "__main__":
    main()
