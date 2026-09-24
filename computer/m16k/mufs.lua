-- m16k/mufs.lua -- host-side writer for the MUNIX "MUFS" disk image.
--
-- fs.inc owns the disk while the machine is running; this module is for
-- the *host* (m16k.lua, sdktest) to put a file on the image from the
-- outside, mirroring fs_format/fs_create exactly:
--
--   0x00        "MUFS" magic
--   0x10        32 directory entries x 32 bytes: name[16] NUL-padded,
--               start block, length lo, length hi
--   0x410       allocation bitmap (byte = block>>3, mask = 1<<(block%8))
--   block 5+    file data, contiguous; block N lives at offset N*256
--
-- `disk` is the machine's 32 KB byte array: 1-based, machine.disk.

local mufs = {}

local DIR    = 0x10
local BITMAP = 0x410
local FIRST  = 5            -- blocks 0-4 hold header/dir/bitmap
local NBLK   = 128           -- 32 KB / 256
local NENT   = 32

function mufs.formatted(disk)
    return disk[1] == 0x4D and disk[2] == 0x55
        and disk[3] == 0x46 and disk[4] == 0x53
end

-- directory index (0-31) holding `name`, or nil. Entry names are
-- NUL-padded to 16 bytes, so a straight 16-byte compare is exact.
local function find(disk, name)
    for i = 0, NENT - 1 do
        local e = DIR + i * 32          -- 0-based offset of the entry
        if (disk[e + 1] or 0) ~= 0 then -- live entry
            local hit = true
            for j = 1, 16 do
                if (disk[e + j] or 0) ~= (name:byte(j) or 0) then
                    hit = false
                    break
                end
            end
            if hit then return i end
        end
    end
    return nil
end

function mufs.exists(disk, name)
    return find(disk, name) ~= nil
end

-- is block b free? (same bit math as fs_bitpos/fs_testbit)
local function blkFree(disk, b)
    local byte = disk[BITMAP + math.floor(b / 8) + 1] or 0
    return math.floor(byte / 2 ^ (b % 8)) % 2 == 0
end

-- Place `data` under `name`. Returns true, or false + reason. A file
-- that already exists is a no-op success (same as myos's old every-boot
-- "is it there yet?" check). Min 1 block, like fs_create.
function mufs.install(disk, name, data)
    if not mufs.formatted(disk) then
        return false, "disk is not formatted"
    end
    if #name == 0 or #name > 16 then return false, "bad file name" end
    if find(disk, name) then return true end

    local blocks = math.max(1, math.ceil(#data / 256))
    if blocks > NBLK - FIRST then return false, "file too big" end

    -- first-fit contiguous run, the scan fs_create does (must end <= 127)
    local startb
    for b = FIRST, NBLK - blocks do
        local free = true
        for k = 0, blocks - 1 do
            if not blkFree(disk, b + k) then free = false break end
        end
        if free then startb = b break end
    end
    if not startb then return false, "disk full" end

    -- a free directory slot (name[0] == 0)
    local slot
    for i = 0, NENT - 1 do
        local e = DIR + i * 32
        if (disk[e + 1] or 0) == 0 then slot = e break end
    end
    if not slot then return false, "directory full" end

    -- data. Stale bytes past the length are never read: fs_open trusts
    -- the length in the entry (fs_create does not zero the tail either).
    for i = 1, #data do
        disk[startb * 256 + i] = data:byte(i)
    end

    -- bitmap: mark the run used (the bits are free, so + is OR)
    for k = 0, blocks - 1 do
        local b = startb + k
        local idx = BITMAP + math.floor(b / 8) + 1
        disk[idx] = (disk[idx] or 0) + 2 ^ (b % 8)
    end

    -- directory entry: zero it, then name[16] + start + len lo/hi
    for j = 1, 32 do disk[slot + j] = 0 end
    for j = 1, #name do disk[slot + j] = name:byte(j) end
    disk[slot + 17] = startb
    disk[slot + 18] = #data % 256
    disk[slot + 19] = math.floor(#data / 256) % 256
    return true
end

return mufs
