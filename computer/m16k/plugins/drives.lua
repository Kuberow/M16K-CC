-- m16k/plugins/drives.lua -- Example M16K storage plugin.
--
-- Backs the machine's stores onto real disk drives (the `drive` peripheral
-- from the CC: Tweaked peripheral API, attachable to any side in CraftOS-PC
-- with `attach <side> drive` / periphemu.create):
--
--   * RAM  (16 KB image)  -> disk in the drive on the TOP side
--   * disk (32 KB image)  -> disk in the drive on the RIGHT side
--
-- The file lives on the drive's *mount* (disk.getMountPath(side), e.g.
-- "disk/" / "disk1/"), so the machine's memory is literally stored on the
-- floppy. Sides can be overridden:
--
--   m16k -p drives
--   -- or from Lua: storage.open("drives", "", { ramSide = "top", diskSide = "right" })

local plugin = {}
plugin.name = "drives"

local RAM_FILE = "m16k-ram.bin"
local DISK_FILE = "m16k-disk.bin"

local function splice(data, offset, chunk)
    return data:sub(1, offset) .. chunk .. data:sub(offset + #chunk + 1)
end

-- Validate the side has a drive with a mounted disk; return its mount path
-- (always with a trailing slash).
local function mountOf(side, role)
    if not peripheral.isPresent(side) then
        error(("no peripheral on the %s side -- attach a disk drive there (%s backing)"):format(side, role), 0)
    end
    local ptype = peripheral.getType(side)
    if ptype ~= "drive" then
        error(("the %s side has a '%s', not a disk drive (%s backing needs a drive)")
            :format(side, tostring(ptype), role), 0)
    end
    if not disk.hasData(side) then
        error(("no disk inserted in the %s-side drive -- insert one for %s backing"):format(side, role), 0)
    end
    local mount = disk.getMountPath(side)
    if not mount then
        error(("the %s-side drive has no mountable disk (%s backing)"):format(side, role), 0)
    end
    if mount:sub(-1) ~= "/" then mount = mount .. "/" end
    return mount
end

function plugin.open(config, helpers)
    config = config or {}
    local ramSide = config.ramSide or "top"
    local diskSide = config.diskSide or "right"

    local RAM_SIZE = config.ramSize or 16384
    local DISK_SIZE = config.diskSize or 32768

    local ramMount = mountOf(ramSide, "RAM")
    local diskMount = mountOf(diskSide, "disk")

    -- Make sure each floppy actually has room (fs.getFreeSpace, CC: Tweaked fs API)
    local ramFree = fs.getFreeSpace(ramMount)
    if type(ramFree) == "number" and ramFree < RAM_SIZE then
        error(("disk in the %s drive is full (%d bytes free, need %d for RAM)")
            :format(ramSide, ramFree, RAM_SIZE), 0)
    end
    local diskFree = fs.getFreeSpace(diskMount)
    if type(diskFree) == "number" and diskFree < DISK_SIZE then
        error(("disk in the %s drive is full (%d bytes free, need %d for the disk image)")
            :format(diskSide, diskFree, DISK_SIZE), 0)
    end

    local ramPath = ramMount .. RAM_FILE
    local diskPath = diskMount .. DISK_FILE

    local ram = helpers.pad(helpers.readFile(ramPath), RAM_SIZE)
    local diskData = helpers.pad(helpers.readFile(diskPath), DISK_SIZE)
    local ramDirty, diskDirty = false, false

    local backend = {
        name = ("drives (RAM: %s drive, disk: %s drive)"):format(ramSide, diskSide),
        ramPath = ramPath,
        diskPath = diskPath,
    }

    function backend.ramRead(offset, length)
        return ram:sub(offset + 1, offset + length)
    end
    function backend.ramWrite(offset, chunk)
        ram = splice(ram, offset, chunk)
        ramDirty = true
    end
    function backend.diskRead(offset, length)
        return diskData:sub(offset + 1, offset + length)
    end
    function backend.diskWrite(offset, chunk)
        diskData = splice(diskData, offset, chunk)
        diskDirty = true
    end

    local function persist()
        -- A drive may have been ejected mid-run; surface that clearly.
        if ramDirty then
            helpers.writeFile(ramPath, ram)
            ramDirty = false
        end
        if diskDirty then
            helpers.writeFile(diskPath, diskData)
            diskDirty = false
        end
    end

    function backend.flush()
        local ok, err = pcall(persist)
        if not ok then
            -- retry once next time; don't kill the machine for it
            ramDirty, diskDirty = true, true
            error(err, 0)
        end
    end
    function backend.close()
        persist()
    end

    return backend
end

return plugin
