# 插件作者与致谢（Credits）

本装机包内非 KOReader 内置的插件/组件来源与作者如下。
"ChuckLee93" 为本包整理者对自研/自改部分的署名。

## 一、KOReader 插件（koplugin）

| 组件 | 原作者（GitHub/Gitee） | 本包改动 |
|---|---|---|
| 觅阅 miuread（微信读书客户端） | [miumiupy98-art](https://github.com/miumiupy98-art/miuread-koreader) | 原版收录 |
| 番茄阅读 fanqie.koplugin（番茄小说客户端） | [hesan1232](https://github.com/hesan1232/fanqie.koplugin)（B 站 UP 主"禾三1232"） | 原版 v2.2.1（2026-08-09 官方 Release 收录，未改动） |
| 拼音输入法 pinyinime（全拼/混拼/双拼，万象词库） | Merpyzf | 原版 v1.2.0（2026-08-30 替换原 pinyin_enhancement，未改动） |
| Z-library | [ZlibraryKO](https://github.com/ZlibraryKO/zlibrary.koplugin) | 原版 v1.0.47 |
| 生僻字注音 pinyin | **zhouwt**（原作者）；拼音数据 © [mozillazg/pinyin-data](https://github.com/mozillazg/pinyin-data)（MIT）与 Unicode Unihan | ChuckLee93 自改版 |
| KOAI（AI 伴读，DeepSeek） | [mufeng0199/KOAI-Reader](https://github.com/mufeng0199/KOAI-Reader)（原版 KOAI）与 [chunbo129/AIReadingAssistant](https://github.com/chunbo129/AIReadingAssistant) | ChuckLee93 根据两者合并改进 |
| 锁屏壁纸 customisablesleepscreen | [pxlflux](https://github.com/pxlflux/customisablesleepscreen.koplugin) | ChuckLee93 自改（书内书外双壁纸） |
| simpleUI | [doctorhetfield-cmd](https://github.com/doctorhetfield-cmd/simpleui.koplugin)（Doctor Hetfield） | 汉化：菠萝油 |
| FilebrowserPlus（无线上传引导） | [patelneeraj](https://github.com/patelneeraj/filebrowserplus.koplugin)（衍生自 filebrowser.koplugin；内嵌 [filebrowser](https://github.com/filebrowser/filebrowser) 服务端） | 原版 v1.2.0 |
| 蓝牙/外接键盘 externalkeyboard | KOReader 官方内置插件（本包仅代为分发，未改动） | — |
| SSH 远程连接（12 号组合配套组件，供蓝牙翻页器使用） | KOReader 官方内置插件（本包仅代为分发，未改动） | — |

## 二、KOReader 补丁（patches）

| 补丁 | 原作者 | 本包改动 |
|---|---|---|
| 阅读小票（胶片版）2-book-receipt-shortcut-and-lockscreen.lua | [omer-faruq](https://github.com/omer-faruq/koreader-user-patches)（原始代码出自 Reddit 用户 hundredpercentcocoa，GPLv3） | 原版收录（未改动） |
| 低内存保护（defaults.custom.lua，页面缓存预算压至 0.15） | 觅阅 miuread（[miumiupy98-art](https://github.com/miumiupy98-art/miuread-koreader)）自带的推荐配置 | 原样收录；装机时询问是否启用（老机型 KPW4 及更早推荐，新机型不推荐）；独立生效，不装觅阅也可启用 |
| 诊断探针 2-diag-probe.lua（定期生成 diag_report.txt 供远程排障） | **ChuckLee93**（原创） | ChuckLee93 自研 |
| 重启抓栈探针 2-restart-diag.lua（KOReader 退出/重启瞬间把发起方调用栈写入 crash.log） | **ChuckLee93**（原创） | ChuckLee93 自研 |

## 三、Kindle 端组件（非 koplugin；均为备用组件——封面入口功能 KOReader/simpleUI 已自带，默认装机流程不安装）

| 组件 | 原作者 | 本包改动 |
|---|---|---|
| KOLBooklet（书库直接进 KOReader） | yparitcher（KOL 分支）；基于 KUAL：ixtab、twobob、stepk、NiLuJe、Coplate 等团队成果 | 原版 v1.5（注：Kindle 系统层 booklet，非 KOReader 插件，也非 KOReader 内置） |
| CoverSetter（KUAL/KOL 换封面） | cearp、Dark_AssassinUA、Targit、Stanner（MobileRead KUAL 扩展） | 原版 |
| 翻页动画 Swipe_Animation | xhs:5699990012、nuku、Echoes、小红薯6809667F、斯普特尼克的漫游 | 原版 v4.2 |

## 四、其他素材来源

- 词典：12 部 stardict 词典，版权归原作者/出版社所有，仅供个人学习使用
- 字体：6 款中文字体，版权归原作者所有，仅供个人学习使用
- 壁纸：猫猫探头、撕纸两张锁屏壁纸，版权归原作者所有

感谢以上所有作者的开源分享。各插件遵循其原许可证（GPLv3 / AGPLv3 / MIT 等），
本包仅作个人装机配置复刻用途分发，请勿商用。
