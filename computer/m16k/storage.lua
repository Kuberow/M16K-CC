-- m16k/storage.lua -- Storage plugin system for the M16K.
--
-- The M16K has two persistent stores:
--   * "ram"  -- the machine's 16 KB RAM image (flushed periodically)
--   * "disk" -- the machine's 32 KB disk image (windowed at 0xE800)
--
-- A *storage plugin* decides where those stores live. Plugins are plain
-- Lua files in m16k/plugins/<name>.lua that return a table:
--
--   local plugin = {}
--   plugin.name = "drives"
--   function plugin.open(config, helpers)
--       -- called once at boot; may error() with a user-facing message
--       return {
--           name       = "drives",            -- optional label
--           ramRead    = function(offset, length) return data end,  -- string
--           ramWrite   = function(offset, chunk) end,               -- 0-based
--           diskRead   = function(offset, length) return data end,
--           diskWrite  = function(offset, chunk) end,
--           flush      = function() end,       -- persist to backing store
--           close      = function(),           -- final flush + cleanup
--       }
--   end
--   return plugin
--
-- helpers (2nd argument of open) provides:
--   helpers.readFile(path)  -> string|nil        (binary, via fs)
--   helpers.writeFile(path, data)                (binary, creates dirs)
--   helpers.pad(s, size)    -> string            (zero-pad/truncate)
--
-- With no plugin selected, storage reverts to the default backend, which
-- keeps BOTH stores on the computer's own disk (fs API):
--   <base>m16k/data/ram.bin
--   <base>m16k/data/disk.bin

local storage = {}

storage.RAM_SIZE = 16384
storage.DISK_SIZE = 32768

--------------------------------------------------------------------
-- helpers (also handed to plugins)
--------------------------------------------------------------------

local helpers = {}

function helpers.readFile(path)
    local h = fs.open(path, "rb")
    if not h then return nil end
    local ok, data = pcall(h.readAll)
    h.close()
    if not ok then return nil end
    return data
end

function helpers.writeFile(path, data)
    local dir = fs.getDir(path)
    if dir ~= "" then fs.makeDir(dir) end
    local h, err = fs.open(path, "wb")
    if not h then
        error("cannot open " .. path .. " for writing: " .. tostring(err), 0)
    end
    h.write(data)
    h.close()
end

function helpers.pad(s, size)
    s = s or ""
    if #s > size then return s:sub(1, size) end
    if #s < size then return s .. string.rep("\0", size - #s) end
    return s
end

storage.helpers = helpers

-- Splice `chunk` into `data` at 0-based `offset`.
local function splice(data, offset, chunk)
    return data:sub(1, offset) .. chunk .. data:sub(offset + #chunk + 1)
end

--------------------------------------------------------------------
-- Default backend: everything on the computer's own disk
--------------------------------------------------------------------

function storage.defaultBackend(base)
    local dataDir = base .. "m16k/data/"
    local ramPath = dataDir .. "ram.bin"
    local diskPath = dataDir .. "disk.bin"

    -- Load (or zero-initialise) both stores up front.
    local ram = helpers.pad(helpers.readFile(ramPath), storage.RAM_SIZE)
    local disk = helpers.pad(helpers.readFile(diskPath), storage.DISK_SIZE)
    local wrote = false

    local backend = {
        name = "default (computer disk)",
        ramPath = ramPath,
        diskPath = diskPath,
    }

    function backend.ramRead(offset, length)
        return ram:sub(offset + 1, offset + length)
    end
    function backend.ramWrite(offset, chunk)
        ram = splice(ram, offset, chunk)
        wrote = true
    end
    function backend.diskRead(offset, length)
        return disk:sub(offset + 1, offset + length)
    end
    function backend.diskWrite(offset, chunk)
        disk = splice(disk, offset, chunk)
        wrote = true
    end
    function backend.flush()
        if wrote then
            helpers.writeFile(ramPath, ram)
            helpers.writeFile(diskPath, disk)
            wrote = false
        end
    end
    function backend.close()
        backend.flush()
    end

    return backend
end

--------------------------------------------------------------------
-- Plugin loading
--------------------------------------------------------------------

-- Attempt to load a plugin backend.
--   name   : plugin file name without .lua (nil/""/"none" => default)
--   base   : install base path ("" when installed at computer root)
--   config : table passed to plugin.open
--   strict : if true, errors abort; otherwise fall back to default
-- Returns: backend, label  or  nil, errmsg  (strict mode only)
function storage.open(name, base, config, strict)
    if not name or name == "" or name == "none" or name == "default" then
        local b = storage.defaultBackend(base)
        return b, b.name
    end

    local path = base .. "m16k/plugins/" .. name .. ".lua"
    local fn, lerr = loadfile(path)
    if not fn then
        local msg = "cannot load plugin '" .. name .. "': " .. tostring(lerr)
        if strict then error(msg, 0) end
        print("m16k: " .. msg)
        print("m16k: reverting to the computer's disk for RAM and disk.")
        local b = storage.defaultBackend(base)
        return b, b.name
    end

    local ok, plugin = pcall(fn)
    if not ok or type(plugin) ~= "table" or type(plugin.open) ~= "function" then
        local msg = "plugin '" .. name .. "' is invalid: " ..
            tostring(ok and "did not return a plugin table" or plugin)
        if strict then error(msg, 0) end
        print("m16k: " .. msg)
        print("m16k: reverting to the computer's disk for RAM and disk.")
        local b = storage.defaultBackend(base)
        return b, b.name
    end

    local ok2, backend = pcall(plugin.open, config or {}, helpers)
    if not ok2 then
        local msg = "plugin '" .. name .. "' failed to open: " .. tostring(backend)
        if strict then error(msg, 0) end
        print("m16k: " .. msg)
        print("m16k: reverting to the computer's disk for RAM and disk.")
        local b = storage.defaultBackend(base)
        return b, b.name
    end
    if type(backend) ~= "table" then
        local msg = "plugin '" .. name .. "' did not return a backend"
        if strict then error(msg, 0) end
        print("m16k: " .. msg)
        print("m16k: reverting to the computer's disk for RAM and disk.")
        local b = storage.defaultBackend(base)
        return b, b.name
    end

    local label = backend.name or ("plugin '" .. name .. "'")
    return backend, label
end

-- List installed plugin names (for --list-plugins / error messages).
function storage.listPlugins(base)
    local names = {}
    local path = base .. "m16k/plugins"
    if fs.exists(path) and fs.isDir(path) then
        for _, f in ipairs(fs.list(path)) do
            local n = f:match("^(.+)%.lua$")
            if n then names[#names + 1] = n end
        end
    end
    return names
end

return storage
