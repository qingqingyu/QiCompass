# 官网 Web 字体源文件(S01)

`tools/build_site_fonts.py` 的输入,全部进 git 保证构建确定性(同 build_songti_fonts.py 不同:iOS 脚本源字体放 /private/tmp 是一次性环境,官网字体源直接留仓)。

| 文件 | 来源 | 许可 |
|---|---|---|
| `Newsreader-var.ttf` | google/fonts `ofl/newsreader`,commit `8b0a1d0f5983`(2026-03-12),变量轴 wght 200-800 + opsz 6-72 | OFL 1.1(见 OFL.txt) |
| `Newsreader-Italic-var.ttf` | 同上(Italic) | OFL 1.1 |
| `OFL.txt` | 同仓原样保留(OFL 分发要求随附许可) | — |

SHA256(2026-11-25 下载):
- `Newsreader-var.ttf` `8a08d13f8a6c0d51be379a60af84f945f65369a67e509ee3c3bdcc421254d7c1`
- `Newsreader-Italic-var.ttf` `796668611f80b64d5adf182fde3b6f29ed83b4e7cbec7b96937e84ac01364792`

中文字体源不在此目录:复用 iOS 已提交的 `ios/QiCompass/QiCompass/Resources/QiSongti-Regular.otf`(SC)与 `QiSongtiTC-Regular.otf`(TC)做二次子集,只读不改。
