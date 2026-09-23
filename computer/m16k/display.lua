-- m16k/display.lua -- Renders the M16K framebuffer with the CraftOS-PC
-- graphics API (https://www.craftos-pc.cc/docs/gfxmode).
--
-- Primary path (CraftOS-PC graphics mode 1):
--   term.setGraphicsMode(1)          -- 16-colour pixel mode
--   term.getSize(1)                  -- pixel dimensions of mode 1
--   term.setFrozen(true/false)       -- double-buffer, no flicker
--   term.drawPixels(x, y, lines)     -- one string per row, byte = palette index
--
-- Fallback path (no graphics API, e.g. CC: Tweaked or CLI renderer):
--   term.blit sampled down to the text grid.
--
-- The framebuffer is 306x171, which is exactly one default CraftOS-PC
-- terminal (51 x 19 CC characters at 6 x 9 graphics pixels each). So the
-- normal case is a straight 1:1 copy: one framebuffer pixel = one graphics
-- pixel, no scaler, no black bars. VRAM stores 2 pixels per byte (high
-- nibble = even x), so every row is unpacked on the way out.
--
-- M16K palette index = CraftOS/CC palette slot, i.e. byte i is colours[2^i]:
--   0 white, 1 orange, 2 magenta, 3 lightBlue, 4 yellow, 5 lime, 6 pink,
--   7 grey, 8 lightGrey, 9 cyan, 10 purple, 11 blue, 12 brown, 13 green,
--   14 red, 15 black

local display = {}

local W, H = 306, 171
local ROWB = W / 2                 -- VRAM bytes per pixel row

-- picture size in CC characters (1 char = 6 x 9 graphics pixels):
-- 51 x 19 = 306 x 171 gfx px = exactly the framebuffer, so at the default
-- window size the picture covers the terminal edge to edge. If the window
-- is clamped *below* the default we scale down to fit; black then appears
-- only in the margins of a larger window.
local PIC_COLS, PIC_ROWS = 51, 19
local PIC_W, PIC_H = PIC_COLS * 6, PIC_ROWS * 9

local gfx = false
local frozen = false
local HEX = "0123456789abcdef"

local function has(fn)
    return type(fn) == "function"
end

-- Enter graphics mode. Returns true if pixel mode is active.
function display.init()
    gfx = false
    if has(term.setGraphicsMode) and has(term.drawPixels) then
        local ok = pcall(term.setGraphicsMode, 1)
        if ok and has(term.getGraphicsMode) then
            local m = term.getGraphicsMode()
            gfx = (m ~= false and m ~= nil and m ~= 0)
        elseif ok then
            gfx = true
        end
    end
    if not gfx then
        -- text fallback: blank the screen so we start clean
        -- (CC colour constants are bit masks: white = 1, black = 2^15)
        pcall(function()
            term.setBackgroundColour(32768)
            term.setTextColour(1)
            term.clear()
            term.setCursorPos(1, 1)
        end)
    else
        -- wipe any leftover frame from a previous run (CraftOS-PC keeps
        -- the last graphics image on screen until something overwrites it)
        pcall(function()
            if has(term.setFrozen) then term.setFrozen(true) end
            term.clear()
            if has(term.setFrozen) then term.setFrozen(false) end
        end)
    end
    pcall(term.setCursorBlink, false)
    return gfx
end

function display.isGraphics()
    return gfx
end

-- cache of string.rep(byte, n) for palette bytes
local REP = {}
for v = 0, 15 do
    REP[v] = {}
    for n = 1, 8 do REP[v][n] = string.rep(string.char(v), n) end
end

-- Unpack VRAM (2 pixels/byte) into one W-wide palette-index string per row.
local function unpackRows(vram)
    local src, parts = {}, {}
    for y = 0, H - 1 do
        local base = y * ROWB
        for b = 0, ROWB - 1 do
            local v = vram[base + b + 1] or 0
            local hi = (v - v % 16) / 16
            parts[b + 1] = REP[hi][1] .. REP[v % 16][1]   -- 2 px/byte -> 306
        end
        src[y + 1] = table.concat(parts)
    end
    return src
end

local function presentGfx(vram)
    local pw, ph = term.getSize(1)
    if type(pw) ~= "number" or type(ph) ~= "number" or pw < W or ph < H then
        -- old CraftOS-PC or redirected terminal: fall back to text size
        pw, ph = term.getSize()
    end
    -- fill the default 51 x 19 CC-character picture box (306 x 171 graphics
    -- pixels), centred in the terminal; clamped down only if the window is
    -- smaller than the default.
    local TW, TH = math.min(PIC_W, pw), math.min(PIC_H, ph)
    local x0 = math.max(0, math.floor((pw - TW) / 2))
    local y0 = math.max(0, math.floor((ph - TH) / 2))

    local src = unpackRows(vram)
    local lines = src
    if TW ~= W or TH ~= H then
        -- window clamped below the default: nearest-neighbour down to fit
        lines = {}
        for ty = 0, TH - 1 do
            local sy = src[math.floor(ty * H / TH) + 1]
            local row = {}
            for tx = 0, TW - 1 do
                local sx = math.floor(tx * W / TW) + 1
                row[tx + 1] = sy:sub(sx, sx)
            end
            lines[ty + 1] = table.concat(row)
        end
    end

    if has(term.setFrozen) then
        term.setFrozen(true)
        frozen = true
    end
    term.drawPixels(x0, y0, lines)
    if frozen then
        term.setFrozen(false)
        frozen = false
    end
end

-- Sample the framebuffer onto the character grid with term.blit.
local function presentText(vram)
    local w, h = term.getSize()
    term.setCursorBlink(false)
    for ty = 1, h do
        local gy = math.min(H - 1, math.floor((ty - 1) * H / h))
        local base = gy * W
        local chars, fgs, bgs = {}, {}, {}
        for tx = 1, w do
            local gx = math.min(W - 1, math.floor((tx - 1) * W / w))
            local i = base + gx
            local b = vram[math.floor(i / 2) + 1] or 0
            local idx = (i % 2 == 0) and math.floor(b / 16) or (b % 16)
            local digit = HEX:sub(idx + 1, idx + 1)
            chars[tx] = " "
            fgs[tx] = digit
            bgs[tx] = digit
        end
        term.setCursorPos(1, ty)
        term.blit(table.concat(chars), table.concat(fgs), table.concat(bgs))
    end
end

-- Present the 306x171 framebuffer.
function display.present(vram)
    if gfx then
        local ok, err = pcall(presentGfx, vram)
        if ok then return true end
        -- graphics mode broke at runtime: log once, switch to text
        gfx = false
        pcall(function() term.setGraphicsMode(false) end)
        print("m16k: graphics present failed (" .. tostring(err) .. "), using text mode")
    end
    pcall(presentText, vram)
    return false
end

-- Restore the terminal (call on exit).
function display.shutdown()
    if frozen then
        pcall(function() term.setFrozen(false) end)
        frozen = false
    end
    if gfx then
        pcall(function() term.setGraphicsMode(false) end)
        gfx = false
    end
    pcall(term.setCursorBlink, true)
end

return display
