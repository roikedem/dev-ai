#!/usr/bin/env python3
"""Plain text with light markup -> Jira ADF, for agent comments.

Agents write Jira wiki markup (*bold*, {{code}}, "* " / "** " bullets) or markdown (**bold**, `code`, "- " bullets, "1. "). The v3 API takes
ADF only, so without this the markup shows up literally and the comment is
unreadable. "@Roi" / "@Roi Kedem" becomes a real mention so Roi is notified.

Usage: jira_adf.py < text   -> prints {"body": <adf doc>}
"""
import json
import re
import sys

ROI_ID = "557058:9d9d1c56-8b3e-473c-953f-546715de7f0f"

INLINE = re.compile(
    r"(?P<mention>@Roi(?: Kedem)?\b)"
    r"|\{\{(?P<wcode>.+?)\}\}"
    r"|`(?P<mcode>[^`]+)`"
    r"|\*\*(?P<mbold>[^*]+?)\*\*"
    r"|(?<![\w*])\*(?P<wbold>[^*\s][^*]*?)\*(?![\w*])"
    r"|\[(?P<ltext>[^\]|]+)\|(?P<lurl>https?://[^\]]+)\]"
    r"|\[(?P<mtext>[^\]]+)\]\((?P<murl>https?://[^)]+)\)"
    r"|(?P<url>https?://[^\s)\]]+)")


def inline(text):
    out, pos = [], 0

    def txt(s, marks=None):
        if s:
            out.append({"type": "text", "text": s, **({"marks": marks} if marks else {})})

    for m in INLINE.finditer(text):
        txt(text[pos:m.start()])
        g = m.groupdict()
        if g["mention"]:
            out.append({"type": "mention", "attrs": {"id": ROI_ID, "text": "@Roi Kedem"}})
        elif g["wcode"] or g["mcode"]:
            txt(g["wcode"] or g["mcode"], [{"type": "code"}])
        elif g["mbold"] or g["wbold"]:
            for n in inline(g["mbold"] or g["wbold"]):
                if not any(mk["type"] == "code" for mk in n.get("marks", [])):  # ADF: code takes no strong
                    n.setdefault("marks", []).append({"type": "strong"})
                out.append(n)
        elif g["lurl"] or g["murl"]:
            txt(g["ltext"] or g["mtext"], [{"type": "link", "attrs": {"href": g["lurl"] or g["murl"]}}])
        else:
            txt(g["url"], [{"type": "link", "attrs": {"href": g["url"]}}])
        pos = m.end()
    txt(text[pos:])
    return out


LIST = re.compile(r"^(?P<ind>\s*)(?P<mark>\*+|-|\d+\.)\s+(?P<body>.*)$")


def list_item(line):
    """(kind, depth, body) for a list line, else None."""
    m = LIST.match(line)
    if not m:
        return None
    mark, ind = m["mark"], len(m["ind"]) // 2
    if mark[0] == "*":
        return "bulletList", len(mark) - 1, m["body"]
    return ("bulletList" if mark == "-" else "orderedList"), ind, m["body"]


def build_list(items, i, depth):
    """Consume items[i:] at >= depth; return (list node, next index)."""
    kind = items[i][0]
    node = {"type": kind, "content": []}
    while i < len(items) and items[i][1] >= depth:
        k, d, body = items[i]
        if d > depth and node["content"]:
            sub, i = build_list(items, i, d)
            node["content"][-1]["content"].append(sub)
            continue
        if k != kind and d == depth:
            break
        node["content"].append({"type": "listItem", "content": [
            {"type": "paragraph", "content": inline(body) or [{"type": "text", "text": " "}]}]})
        i += 1
    return node, i


def to_adf(text):
    blocks, lines, i = [], text.split("\n"), 0
    while i < len(lines):
        line = lines[i]
        if line.strip().startswith("```") or line.strip().startswith("{code"):
            fence, code, i = line.strip()[:3], [], i + 1
            while i < len(lines) and not lines[i].strip().startswith(fence if fence == "```" else "{code"):
                code.append(lines[i])
                i += 1
            blocks.append({"type": "codeBlock", "content": [{"type": "text", "text": "\n".join(code) or " "}]})
            i += 1
            continue
        if list_item(line):
            items = []
            while i < len(lines) and list_item(lines[i]):
                items.append(list_item(lines[i]))
                i += 1
            j = 0
            while j < len(items):
                node, j = build_list(items, j, items[j][1])
                blocks.append(node)
            continue
        h = re.match(r"^(?:h([1-6])\.|(#{1,6}))\s+(.*)$", line)
        if h:
            blocks.append({"type": "heading", "attrs": {"level": int(h[1] or len(h[2]))},
                           "content": inline(h[3])})
        elif line.strip():
            blocks.append({"type": "paragraph", "content": inline(line)})
        i += 1
    return {"type": "doc", "version": 1,
            "content": blocks or [{"type": "paragraph", "content": [{"type": "text", "text": " "}]}]}


if __name__ == "__main__":
    print(json.dumps({"body": to_adf(sys.stdin.read())}))
