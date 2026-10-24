#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把架构文档转成**手机可读**的单文件 HTML（零外链，可离线转发）。

用法：  python3 tool/md2phone.py docs/xxx.md [out.html]

为什么自写模板：这份图的命门是 ① 几十个宽表（手机上必须横向滚而不是压成一团）
② ASCII 子图（必须等宽 + 不折行 + 横向滚，否则 A/B/C/D/E 子图全部错位）
③ 目录要能收起来（1400+ 行在手机上直接翻是灾难）。
"""
import re, sys, os, html, datetime
import markdown

def slug(t, used):
    s = re.sub(r'[^\w\u4e00-\u9fff.-]+', '-', t).strip('-').lower() or 'sec'
    if s in used:
        s = f"{s}-{used[s]}"; used[s] = used[s] + 1
    else:
        used[s] = 1
    return s

def main(src, out):
    text = open(src, encoding='utf-8').read()
    md = markdown.Markdown(extensions=['tables', 'fenced_code', 'sane_lists', 'attr_list'])
    body = md.convert(text)

    # 标题加锚点 + 造目录（只收 h2/h3，h1 是文档名）
    used, toc = {}, []
    def hook(m):
        lvl, attrs, inner = m.group(1), m.group(2) or '', m.group(3)
        sid = slug(re.sub(r'<[^>]+>', '', inner).strip(), used)
        if lvl in ('2', '3'):
            toc.append((int(lvl), sid, re.sub(r'<[^>]+>', '', inner).strip()))
        return f'<h{lvl} id="{sid}"{attrs}>{inner}</h{lvl}>'
    body = re.sub(r'<h([1-6])([^>]*)>(.*?)</h\1>', hook, body, flags=re.S)

    toc_html = []
    for lvl, sid, t in toc:
        toc_html.append(f'<a class="t{lvl}" href="#{sid}">{html.escape(t)}</a>')
    title = os.path.basename(src).rsplit('.', 1)[0]
    stamp = datetime.datetime.now().strftime('%Y-%m-%d %H:%M')
    src_size = os.path.getsize(src)

    doc = f"""<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<title>{html.escape(title)}</title>
<style>
:root{{--bg:#fff;--fg:#111;--mut:#666;--line:#d8d8d8;--card:#f6f7f9;--acc:#0b62c4;--code:#f2f4f7}}
@media (prefers-color-scheme:dark){{:root{{--bg:#111417;--fg:#e8eaed;--mut:#9aa0a6;--line:#33383d;--card:#181c20;--acc:#7cb3ff;--code:#1d2228}}}}
*{{box-sizing:border-box;-webkit-text-size-adjust:100%}}
body{{margin:0;background:var(--bg);color:var(--fg);
 font:16px/1.75 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif;
 word-break:break-word;overflow-wrap:anywhere}}
header{{position:sticky;top:0;z-index:9;background:var(--card);border-bottom:1px solid var(--line);
 padding:10px 12px;display:flex;gap:10px;align-items:center}}
header b{{font-size:15px;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}}
header a{{font-size:13px;color:var(--acc);text-decoration:none;border:1px solid var(--line);
 padding:4px 9px;border-radius:14px;background:var(--bg)}}
main{{max-width:960px;margin:0 auto;padding:14px 12px 90px}}
h1{{font-size:22px;line-height:1.4;margin:6px 0 14px}}
h2{{font-size:19px;margin:30px 0 10px;padding-bottom:6px;border-bottom:2px solid var(--acc)}}
h3{{font-size:17px;margin:22px 0 8px}}
h4{{font-size:15px;margin:16px 0 6px;color:var(--mut)}}
a{{color:var(--acc)}}
p,li{{font-size:15.5px}}
/* 命门 1：宽表横向滚，绝不压行 */
table{{border-collapse:collapse;display:block;overflow-x:auto;max-width:100%;margin:10px 0;
 font-size:13.5px;line-height:1.5;white-space:nowrap}}
th,td{{border:1px solid var(--line);padding:7px 9px;vertical-align:top;text-align:left}}
th{{background:var(--card);position:sticky;top:0}}
td br{{white-space:normal}}
/* 命门 2：ASCII 子图等宽 + 不折行 + 横向滚 */
pre{{background:var(--code);border:1px solid var(--line);border-radius:8px;padding:10px 12px;
 overflow-x:auto;white-space:pre;font:12px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,"Noto Sans Mono CJK SC",monospace}}
code{{background:var(--code);padding:1px 4px;border-radius:4px;font:.88em ui-monospace,Menlo,Consolas,monospace}}
pre code{{background:none;padding:0}}
blockquote{{margin:10px 0;padding:8px 12px;border-left:4px solid var(--acc);background:var(--card);border-radius:0 8px 8px 0}}
hr{{border:0;border-top:1px solid var(--line);margin:26px 0}}
#toc{{display:none;position:fixed;inset:52px 0 auto 0;max-height:72vh;overflow:auto;background:var(--card);
 border-bottom:1px solid var(--line);padding:10px 14px;z-index:8}}
#toc.on{{display:block}}
#toc a{{display:block;padding:5px 0;text-decoration:none;color:var(--fg);border-bottom:1px dashed var(--line);font-size:14px}}
#toc a.t3{{padding-left:18px;color:var(--mut);font-size:13px}}
.top{{position:fixed;right:14px;bottom:18px;z-index:9;background:var(--acc);color:#fff;border-radius:20px;
 padding:8px 13px;font-size:13px;text-decoration:none;opacity:.9}}
.hint{{font-size:12px;color:var(--mut);margin:2px 0 12px}}
.legend span{{display:inline-block;padding:1px 7px;border-radius:10px;border:1px solid var(--line);margin:2px 3px 2px 0;font-size:13px}}
@media print{{header,.top,#toc{{display:none}} pre,table{{white-space:pre-wrap}}}}
</style></head><body>
<header><b>{html.escape(title)}</b><a href="#" onclick="document.getElementById('toc').classList.toggle('on');return false">目录</a><a href="#legend">图例</a></header>
<nav id="toc">{''.join(toc_html)}</nav>
<main>
<div class="legend" id="legend"><span>🟦 不归我们搞</span><span>🟩 已做且验过</span><span>🟨 在做还有问题</span><span>🟥 该做还没做</span><span>⬜ 未核</span></div>
<div class="hint">导出 {stamp} ｜ 源 {os.path.basename(src)}（{src_size//1024} KB，{text.count(chr(10))+1} 行）｜ 表格与 ASCII 图可左右滑动（横向滚动条在块内）</div>
{body}
</main><a class="top" href="#" onclick="scrollTo({{top:0,behavior:'smooth'}});return false">↑</a></body></html>"""

    open(out, 'w', encoding='utf-8').write(doc)
    return out, len(doc), len(toc)

if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit('用法: python3 tool/md2phone.py docs/xxx.md [out.html]')
    s = sys.argv[1]
    o = sys.argv[2] if len(sys.argv) > 2 else re.sub(r'\.md$', '', s) + '.html'
    p, n, t = main(s, o)
    print(f'OK {p}  {n//1024} KB  目录项 {t}')
