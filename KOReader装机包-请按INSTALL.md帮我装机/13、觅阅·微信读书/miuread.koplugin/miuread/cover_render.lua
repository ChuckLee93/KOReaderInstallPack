local Blitbuffer = require("ffi/blitbuffer")
local RenderImage = require("ui/renderimage")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local M = {}

local function free(bb)
    if bb and type(bb.free) == "function" then pcall(bb.free, bb) end
end

local function file_mtime(path)
    return tonumber(lfs.attributes(tostring(path or ""), "modification") or 0) or 0
end

local function file_ok(path)
    return tostring(path or "") ~= "" and lfs.attributes(path, "mode") == "file"
end

local function load(path)
    if not file_ok(path) then return nil end
    local ok, image = pcall(RenderImage.renderImageFile, RenderImage, path, false, nil, nil)
    if not ok or not image then return nil end
    local w = tonumber(image:getWidth()) or 0
    local h = tonumber(image:getHeight()) or 0
    if w <= 0 or h <= 0 then free(image); return nil end
    return image, w, h
end

function M.lower_priority()
    -- Image conversion is intentionally background-only. Keep it below reader
    -- interaction and normal KOReader work on slower Kindle devices.
    pcall(function()
        local ffi = require("ffi")
        ffi.cdef[[int setpriority(int which, int who, int prio);]]
        ffi.C.setpriority(0, 0, 19)
    end)
end

function M.best_source(paths)
    local best_path, best_area = nil, 0
    local seen = {}
    for _, raw in ipairs(paths or {}) do
        local path = tostring(raw or "")
        if path ~= "" and not seen[path] then
            seen[path] = true
            local image, w, h = load(path)
            if image then
                local area = w * h
                if area > best_area then
                    best_path, best_area = path, area
                end
                free(image)
            end
        end
    end
    return best_path, best_area
end

function M.image_size(path)
    local image, w, h = load(path)
    if not image then return nil, nil end
    free(image)
    return w, h
end

-- Build a screen-sized presentation from an already decoded image. The caller
-- owns `image`; this function only owns/free its scaled temporary buffer.
function M.render_screen_image(image, width, height, style, source_label)
    width, height = tonumber(width) or 0, tonumber(height) or 0
    if width <= 0 or height <= 0 or not image then return nil, nil, "invalid direct cover input" end
    local iw = tonumber(image:getWidth()) or 0
    local ih = tonumber(image:getHeight()) or 0
    if iw <= 0 or ih <= 0 then return nil, nil, "invalid direct cover dimensions" end
    style = tostring(style or "frame")
    if style ~= "frame" and style ~= "fit" and style ~= "fill" then style = "frame" end

    local scaled, canvas
    local ok, result = xpcall(function()
        local scale
        if style == "fill" then
            scale = math.max(width / iw, height / ih)
        elseif style == "frame" then
            local max_w = width * .84
            local max_h = height * .86
            scale = math.min(max_w / iw, max_h / ih)
        else
            scale = math.min(width / iw, height / ih)
        end
        local sw = math.max(1, math.floor(iw * scale + .5))
        local sh = math.max(1, math.floor(ih * scale + .5))
        scaled = RenderImage:scaleBlitBuffer(image, sw, sh, false)
        if not scaled then error("cover scale failed") end

        canvas = Blitbuffer.new(width, height, scaled:getType())
        canvas:fill(Blitbuffer.COLOR_WHITE)
        local display_w, display_h = sw, sh
        if style == "fill" then
            local sx = math.max(0, math.floor((sw - width) / 2))
            local sy = math.max(0, math.floor((sh - height) / 2))
            canvas:blitFrom(scaled, 0, 0, sx, sy, width, height)
            display_w, display_h = width, height
        else
            local x = math.floor((width - sw) / 2)
            local y = math.floor((height - sh) / 2)
            if style == "frame" and type(canvas.paintRect) == "function" then
                local border = 1
                local color = Blitbuffer.COLOR_DARK_GRAY
                canvas:paintRect(math.max(0, x-border), math.max(0, y-border), math.min(width, sw+border*2), border, color)
                canvas:paintRect(math.max(0, x-border), math.min(height-border, y+sh), math.min(width, sw+border*2), border, color)
                canvas:paintRect(math.max(0, x-border), math.max(0, y-border), border, math.min(height, sh+border*2), color)
                canvas:paintRect(math.min(width-border, x+sw), math.max(0, y-border), border, math.min(height, sh+border*2), color)
            end
            canvas:blitFrom(scaled, x, y, 0, 0, sw, sh)
        end
        return {
            source = tostring(source_label or "native"), source_w = iw, source_h = ih,
            display_w = display_w, display_h = display_h, style = style,
        }
    end, debug.traceback)

    if scaled ~= image then free(scaled) end
    if not ok then
        free(canvas)
        logger.warn("[MiuRead][CoverRender] direct screensaver render failed", tostring(result))
        return nil, nil, result
    end
    return canvas, result
end

-- Build the sleep-screen presentation only when KOReader is actually entering
-- its screensaver. Nothing is written to disk: the highest-resolution source
-- is decoded once, scaled once, and copied to one screen-sized buffer that the
-- native KOReader Screensaver will display and dispose.
function M.render_screen(paths, width, height, style, native_image, native_label)
    local best, best_path, best_w, best_h, best_area = nil, nil, 0, 0, 0
    local best_owned = false
    if native_image then
        local w = tonumber(native_image:getWidth()) or 0
        local h = tonumber(native_image:getHeight()) or 0
        if w > 0 and h > 0 then
            best, best_path, best_w, best_h, best_area = native_image,
                tostring(native_label or "koreader-native"), w, h, w * h
        end
    end

    local seen = {}
    for _, raw in ipairs(paths or {}) do
        local path = tostring(raw or "")
        if path ~= "" and not seen[path] then
            seen[path] = true
            local image, w, h = load(path)
            if image then
                local area = w * h
                if area > best_area then
                    if best_owned then free(best) end
                    best, best_path, best_w, best_h, best_area = image, path, w, h, area
                    best_owned = true
                else
                    free(image)
                end
            end
        end
    end
    if not best then return nil, nil, "no valid cover source" end
    local canvas, meta, err = M.render_screen_image(best, width, height, style, best_path)
    if best_owned then free(best) end
    return canvas, meta, err
end

function M.is_fresh(target, source)
    if not file_ok(target) then return false end
    local tm = file_mtime(target)
    local sm = file_mtime(source)
    return tm > 0 and tm >= sm
end

local function write_png(canvas, target)
    local tmp = tostring(target) .. ".tmp"
    os.remove(tmp)
    local ok, err = pcall(canvas.writePNG, canvas, tmp)
    if not ok then os.remove(tmp); return nil, err end
    -- POSIX rename replaces the old file atomically. Keep the old cover visible
    -- until the new PNG is complete so the UI never observes a missing-image
    -- window (the checkerboard/blank-cover flash seen on Kindle).
    local renamed, rename_err = os.rename(tmp, target)
    if not renamed then
        -- Conservative fallback for filesystems that refuse replacement.
        os.remove(target)
        renamed, rename_err = os.rename(tmp, target)
    end
    if not renamed then os.remove(tmp); return nil, rename_err or "rename failed" end
    return target
end

-- Aspect-preserving renderer used only for the small home-shelf derivative.
-- The output canvas always has the requested size, while the source image is
-- centered inside it without cropping or stretching.
function M.render_fit(source, target, width, height, options)
    options = options or {}
    width, height = tonumber(width) or 0, tonumber(height) or 0
    if width <= 0 or height <= 0 then return nil, "invalid target size" end
    local image, iw, ih = load(source)
    if not image then return nil, "cover decode failed" end

    local scaled, canvas
    local ok, result = xpcall(function()
        local max_ratio = math.max(.10, math.min(1.0, tonumber(options.max_ratio) or 1.0))
        local max_w = math.max(1, math.floor(width * max_ratio + .5))
        local max_h = math.max(1, math.floor(height * max_ratio + .5))
        local scale = math.min(max_w / iw, max_h / ih)
        local sw = math.max(1, math.floor(iw * scale + .5))
        local sh = math.max(1, math.floor(ih * scale + .5))
        scaled = RenderImage:scaleBlitBuffer(image, sw, sh, false)
        if not scaled then error("cover scale failed") end
        canvas = Blitbuffer.new(width, height, scaled:getType())
        canvas:fill(Blitbuffer.COLOR_WHITE)
        local x = math.floor((width - sw) / 2)
        local y = math.floor((height - sh) / 2)
        local border = options.border == true and math.max(1, tonumber(options.border_size) or 1) or 0
        if border > 0 and type(canvas.paintRect) == "function" then
            local color = options.border_color or Blitbuffer.COLOR_DARK_GRAY
            canvas:paintRect(math.max(0, x-border), math.max(0, y-border), math.min(width, sw+border*2), border, color)
            canvas:paintRect(math.max(0, x-border), math.min(height-border, y+sh), math.min(width, sw+border*2), border, color)
            canvas:paintRect(math.max(0, x-border), math.max(0, y-border), border, math.min(height, sh+border*2), color)
            canvas:paintRect(math.min(width-border, x+sw), math.max(0, y-border), border, math.min(height, sh+border*2), color)
        end
        canvas:blitFrom(scaled, x, y, 0, 0, sw, sh)
        local boost = math.max(0, math.min(.14, tonumber(options.ink_boost) or 0))
        if boost > 0 and type(canvas.darkenRect) == "function" then
            pcall(canvas.darkenRect, canvas, x, y, sw, sh, boost)
        end
        local path, err = write_png(canvas, target)
        if not path then error(err or "cover write failed") end
        return path
    end, debug.traceback)

    if scaled == image then scaled = nil end
    free(image)
    free(scaled)
    free(canvas)
    if not ok then
        logger.warn("[MiuRead][CoverRender] fit render failed", tostring(result))
        return nil, result
    end
    return result
end

-- Home thumbnails are rendered into the final portrait canvas once, preserving
-- the original cover ratio. The home UI can then reuse that canvas directly.
function M.render_home(source, target, width, height)
    return M.render_fit(source, target, width, height, {ink_boost = .035})
end

return M
