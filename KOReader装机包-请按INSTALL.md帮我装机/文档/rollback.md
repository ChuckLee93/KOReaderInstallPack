# 回滚指南

装机过程中 WorkBuddy 会在装机包文件夹旁创建 `backup/` 目录，保存被改动前的设备原文件。
所有回滚都基于这个目录。

## backup/ 目录内容

```
backup/
├── settings.reader.lua            ← 合并前的设备原设置
├── gestures.lua                    ← 覆盖前的设备原手势
├── defaults.custom.lua             ← 覆盖前的设备原文件（如有）
├── simpleui/sui_settings.lua       ← 美化覆盖前原文件（如有）
├── customisablesleepscreen.lua     ← 同上
├── KOAI_settings.json              ← 同上
└── removed-plugins/<名字>.koplugin/ ← 被删除的官方插件完整备份
```

---

## 场景 1：只是想撤销某些设置（整机还能正常进 KOReader）

USB 插电脑（或用 FilebrowserPlus 无线）把 `backup/settings.reader.lua` 复制回
`koreader/settings.reader.lua`，重启 KOReader。
（手势同理：把 `backup/gestures.lua` 复制回 `koreader/settings/gestures.lua`。）

## 场景 2：KOReader 启动即崩溃（frontend 覆盖文件与版本不符）

多半是 `touchmenu.lua` / `menu_activate.lua` / `uimanager.lua` 与设备 KOReader
版本不匹配。回滚方法：

1. USB 连接 Kindle（此时 API 可能起不来，走 USB 最稳）。
2. 从 KOReader 官方发布包（https://github.com/koreader/koreader/releases，选对应版本）
   恢复以下文件，或直接重装 KOReader 到 `koreader/`：
   - `koreader/frontend/ui/widget/touchmenu.lua`
   - `koreader/frontend/ui/elements/menu_activate.lua`
   - `koreader/frontend/ui/uimanager.lua`
   - `koreader/frontend/ui/elements/menu_activate.lua`
3. 删除可疑补丁（`koreader/patches/` 里 2- 开头的文件），重启验证，再逐个加回定位。

## 场景 3：想恢复被删的官方插件

USB 或 API 把 `backup/removed-plugins/<名字>.koplugin/` 传回
`koreader/plugins/<名字>.koplugin/`，重启 KOReader。

## 场景 4：彻底卸载本包装的所有东西

1. 删除 `koreader/plugins/` 下本包装入的插件（含必装与选装的，装了哪个删哪个）：
   `keepalive`、`miuread`、`zlibrary`、`pinyinime`、`pinyin`、`koai`、
   `simpleui`、`customisablesleepscreen`、`fanqie`（`filebrowserplus` 想留就留着）。
2. 删除 `koreader/patches/` 里所有 2- 开头的补丁文件。
3. 按「场景 2」恢复 3 个 frontend 文件（或重装 KOReader）。
4. 用 `backup/` 恢复 settings.reader.lua、gestures.lua、defaults.custom.lua。
5. 恢复 `backup/removed-plugins/` 里的插件。
6. 删除 `koreader/data/dict/` 下的 12 个 stardict 目录、`koreader/fonts/` 下 12 个新 ttf
   （可选，留着也无害）。
7. 删除 `koreader/settings/` 下的 `simpleui/`、`customisablesleepscreen*.lua`、
   `KOAI_settings.json`。

## 预防性建议

- 想从头再来最干净的方式：先把 KOReader 整个 `koreader/` 目录 USB 复制一份留底，
  任何问题直接整体还原。
- KOReader OTA 升级会重置 frontend 文件，升级后需重新上传 3 个覆盖文件与本包新适配版本。
