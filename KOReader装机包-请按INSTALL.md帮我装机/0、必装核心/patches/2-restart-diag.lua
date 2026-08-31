-- 2-restart-diag.lua  重启诊断探针 (RestartDiag)
--
-- 作用: 每次 KOReader 发生重启(exit 85)或 Restart 事件时,
--       把发起者的完整调用栈写进 crash.log, 用来定位"是谁触发的重启"。
--       排查"莫名自动重启/重启循环"专用。
--
-- 安装: 把本文件复制到  koreader/patches/  目录(与其它 2-*.lua 补丁同级),
--       重启 KOReader 生效。不动任何原有文件。
-- 移除: 删除本文件, 重启 KOReader。
-- 看结果: 连电脑或用文件管理器打开  koreader/crash.log,
--         搜索 "[RestartDiag]"(谁请求了重启) 或 "[RestartDiag2]"(谁广播了重启事件),
--         下面的 traceback 就是发起路径(哪个插件/哪个按钮/哪行代码)。
--         把那一段发给别人(AI/论坛)即可帮助定位。
--
-- 原理: 在 UIManager:quit() 与 DeviceListener:onRestart() 两个关键路口包一层钩子,
--       事件发生瞬间抓调用栈; 全程 pcall 保护, 平时零开销(只在退出/重启那一刻动笔)。

pcall(function()
    if _G.__restart_diag_started then return end
    _G.__restart_diag_started = true

    local logger = require("logger")

    -- 探针 #1: 抓"谁请求了 exit code 85(重启)"
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if ok_ui and UIManager and UIManager.quit then
        local orig_quit = UIManager.quit
        UIManager.quit = function(self, exit_code, implicit)
            if exit_code == 85 and not implicit then
                pcall(function()
                    logger.warn("[RestartDiag] explicit quit(85); caller traceback:\n" .. debug.traceback())
                end)
            end
            return orig_quit(self, exit_code, implicit)
        end
    end

    -- 探针 #2: 抓"谁广播了 Restart 事件"(比 #1 更早, 能看到广播者)
    local ok_dl, DeviceListener = pcall(require, "device/devicelistener")
    if ok_dl and DeviceListener and DeviceListener.onRestart then
        local orig_on_restart = DeviceListener.onRestart
        DeviceListener.onRestart = function(self)
            pcall(function()
                logger.warn("[RestartDiag2] Restart event received; broadcaster traceback:\n" .. debug.traceback())
            end)
            return orig_on_restart(self)
        end
    end

    logger.info("[RestartDiag] probes installed (quit85 + onRestart)")
end)
