--[[--
书摘卡片渲染基座（生产入口，薄封装）。

图片合成（离屏 RGB32 渲染 + 写 PNG）的实现拆在 `book_excerpt_card/`：
  config / templates / device / fonts / rgb32 / assets / runes / text /
  draw / vertical / render / init

本模块提供图片合成基座；书摘弹窗 UI、图片保存流程、二维码分享等由调用方自行实现。

KOReader pluginloader 只加 `?.lua`，没有 `?/init.lua`，
因此保留本文件作为 `require("miuread.book_excerpt_card")` 入口。

@module koplugin.miuread.book_excerpt_card
--]]--

return require("miuread.book_excerpt_card.init")
