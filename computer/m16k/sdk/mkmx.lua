-- m16k/sdk/mkmx.lua -- build a MEX executable from assembly source.
--
-- Usage (from the CraftOS shell):
--   mkmx myapp.asm        assemble + wrap as a MEX binary
-- writes m16k/build/<name>.mx (header + 16 var bytes + code).
-- The source must use MEX_BEGIN (org 0x2000); entry is fixed at 0x2010.

local args = { ... }

local unpack = unpack or table.unpack

local progPath = shell.getRunningProgram()
local sdkDir = fs.getDir(progPath)              -- .../m16k/sdk
local root = sdkDir:match("^(.*)/m16k/sdk$") or ""
local base = root == "" and "" or root .. "/"

local function loadMod(rel)
  local fn, lerr = loadfile(base .. rel)
  if not fn then error("mkmx: cannot load " .. rel .. ": " .. tostring(lerr), 0) end
  local ok, mod = pcall(fn, base)
  if not ok then error("mkmx: error loading " .. rel .. ": " .. tostring(mod), 0) end
  return mod
end

local function main()
  if not args[1] then
    print("usage: mkmx <file.asm>    (MEX app source, org 0x2000)")
    return
  end
  local asm = loadMod("m16k/asm.lua")
  local pp = loadMod("m16k/sdk/pp.lua")

  -- resolve the source: as given, in sdk/examples/, or in programs/
  local srcPath
  for _, cand in ipairs({ args[1], sdkDir .. "/examples/" .. args[1],
      base .. "m16k/programs/" .. args[1] }) do
    if fs.exists(cand) then srcPath = cand break end
  end
  if not srcPath then error("mkmx: no such file: " .. args[1], 0) end

  local h = fs.open(srcPath, "rb")
  local raw = h.readAll()
  h.close()
  local src, perr = pp.process(raw, fs.getDir(srcPath))
  if not src then error("mkmx: preprocess failed: " .. tostring(perr), 0) end
  local org, bytes = asm.assemble(src)
  if not org then error("mkmx: assemble failed: " .. tostring(bytes), 0) end
  if org ~= 0x2000 then
    error(string.format("mkmx: source must start at org 0x2000 (got 0x%04X); "
      .. "use %%include \"mex.inc\" + MEX_BEGIN", org), 0)
  end
  if 0x2000 + #bytes > 0x3000 then
    error("mkmx: app body too big (" .. #bytes .. " bytes, max 4096)", 0)
  end

  -- 12-byte MEX header
  local n = #bytes
  local hdr = { 0x4D, 0x58, 1, 0, 0x00, 0x20, 16, 0, n % 256,
    math.floor(n / 256) % 256, 0, 0 }
  local sum = 0
  for i = 1, 10 do sum = sum + hdr[i] end
  hdr[11] = sum % 256

  local parts, t = {}, {}
  parts[#parts + 1] = string.char(unpack(hdr))
  for _, b in ipairs(bytes) do
    t[#t + 1] = b
    if #t == 64 then parts[#parts + 1] = string.char(unpack(t)); t = {} end
  end
  if #t > 0 then parts[#parts + 1] = string.char(unpack(t)) end
  local image = table.concat(parts)

  pcall(fs.makeDir, base .. "m16k/build")
  local name = fs.getName(srcPath):match("^(.*)%.[^%.]+$") or fs.getName(srcPath)
  local outPath = base .. "m16k/build/" .. name .. ".mx"
  local oh = fs.open(outPath, "wb")
  if not oh then error("mkmx: cannot write " .. outPath, 0) end
  oh.write(image)
  oh.close()
  print(string.format("mkmx: %s (%d bytes, entry 0x2010)", outPath, #image))
end

local ok, err = pcall(main)
if not ok then
  print("mkmx: " .. tostring(err))
end
