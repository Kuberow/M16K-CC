-- m16k/sdk/pp.lua -- tiny assembler preprocessor for the M16K SDK.
--
-- Loaded with the install base path as its first vararg (like asm.lua):
--   local pp = loadfile("m16k/sdk/pp.lua")(base)
--   local src, err = pp.process(source, dirOfThisFile)
--
-- Directives (must be the first thing on the line; "%" only ever starts a
-- directive, modulo expressions mid-line are untouched):
--   %include "path"        inline another source file
--   %incbin "path"         emit the file's raw bytes as db data
--   %define NAME text...   whole-word text substitution (never inside "strings")
--   %undef NAME
--   %macro NAME p1, p2     ... %endmacro   invoke as: NAME arg1, arg2
--                          body may use %1..%9 for arguments, %% for a literal %
--   %error message         abort assembly with a message
--
-- Path resolution for %include/%incbin: tried relative to the including
-- file's directory first, then as <base>m16k/sdk/asm/<path> (the SDK
-- include directory).

local base = ...

local pp = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- split on top-level commas, honouring "quotes" and (parentheses)
local function splitArgs(s)
  local items, depth, inq, cur = {}, 0, false, ""
  for i = 1, #s do
    local ch = s:sub(i, i)
    if inq then
      cur = cur .. ch
      if ch == '"' then inq = false end
    elseif ch == '"' then
      inq = true
      cur = cur .. ch
    elseif ch == "(" then
      depth = depth + 1
      cur = cur .. ch
    elseif ch == ")" then
      depth = depth - 1
      cur = cur .. ch
    elseif ch == "," and depth == 0 then
      items[#items + 1] = trim(cur)
      cur = ""
    else
      cur = cur .. ch
    end
  end
  if trim(cur) ~= "" then items[#items + 1] = trim(cur) end
  return items
end

local function readAll(path, mode)
  local h = fs.open(path, mode or "rb")
  if not h then return nil end
  local data = h.readAll()
  h.close()
  return data
end

local function resolve(path, dir)
  local tried, seen = {}, {}
  local function try(p)
    if p == "" or seen[p] then return nil end   -- dedupe (base may be "")
    seen[p] = true
    tried[#tried + 1] = p
    if fs.exists(p) then return p end
    return nil
  end
  -- 1. relative to the including file
  -- 2. relative to the INSTALL ROOT (base): this is what a path like
  --    "m16k/build/hello.mx" means -- without it, an install in a
  --    subdirectory (e.g. <computer>/m16k/) can never resolve, because the
  --    shell's cwd is usually the computer root instead
  -- 3. relative to the shell's cwd
  -- 4. the SDK include directory
  local b = base or ""
  local hit = try((dir or "") .. "/" .. path) or try(b .. path)
    or try(path) or try(b .. "m16k/sdk/asm/" .. path)
  if hit then return hit end
  return nil, "file not found (tried " .. table.concat(tried, ", ") .. ")"
end

-- whole-word substitution of name -> val, never inside double quotes
local function substWord(text, name, val)
  local out, i, insq, n = {}, 1, false, #name
  while i <= #text do
    local c = text:sub(i, i)
    if insq then
      out[#out + 1] = c
      if c == '"' then insq = false end
      i = i + 1
    elseif c == '"' then
      out[#out + 1] = c
      insq = true
      i = i + 1
    elseif text:sub(i, i + n - 1) == name
        and (i == 1 or not text:sub(i - 1, i - 1):match("[%w_]"))
        and (i + n > #text or not text:sub(i + n, i + n):match("[%w_]")) then
      out[#out + 1] = val
      i = i + n
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

local function splitLines(text)
  local lines = {}
  for ln in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = ln:gsub("\r$", "")
  end
  return lines
end

function pp.process(source, dir)
  local defines, macros, out, stack = {}, {}, {}, {}
  local path = "<source>"

  local function fail(n, msg)
    error(path .. ":" .. n .. ": " .. msg, 0)
  end

  local processTable -- forward

  processTable = function(lines, depth)
    if depth > 32 then
      error(path .. ": include nesting too deep (cycle?)", 0)
    end
    local i = 1
    while i <= #lines do
      local raw = lines[i]
      local n = i
      i = i + 1
      local t = trim(raw)
      local dirName, dirArg = t:match("^%%(%S+)%s*(.*)$")

      if dirName then
        dirArg = trim(dirArg)
        if dirName == "include" then
          local want = dirArg:match('^"(.*)"$')
          if not want then fail(n, '%include needs "path" in quotes') end
          local r, err = resolve(want, dir)
          if not r then fail(n, "%include " .. err) end
          if stack[r] then fail(n, "%include cycle on " .. r) end
          local data = readAll(r, "rb")
          if not data then fail(n, "cannot read " .. r) end
          local savedPath, savedDir = path, dir
          path, dir = r, r:match("^(.*)/[^/]*$") or dir
          stack[r] = true
          processTable(splitLines(data), depth + 1)
          stack[r] = nil
          path, dir = savedPath, savedDir
        elseif dirName == "incbin" then
          local want = dirArg:match('^"(.*)"$')
          if not want then fail(n, '%incbin needs "path" in quotes') end
          local r, err = resolve(want, dir)
          if not r then fail(n, "%incbin " .. err) end
          local data = readAll(r, "rb")
          if not data then fail(n, "cannot read " .. r) end
          local j = 1
          while j <= #data do
            local last = math.min(j + 15, #data)
            local parts = {}
            for k = j, last do
              parts[#parts + 1] = string.format("0x%02X", data:byte(k))
            end
            out[#out + 1] = "db " .. table.concat(parts, ",")
            j = last + 1
          end
        elseif dirName == "define" then
          local name, rest = dirArg:match("^(%S+)%s*(.*)$")
          if not name then fail(n, "%define needs a name") end
          defines[name] = rest or ""
        elseif dirName == "undef" then
          defines[dirArg] = nil
        elseif dirName == "macro" then
          local name, plist = dirArg:match("^(%S+)%s*(.*)$")
          if not name then fail(n, "%macro needs a name") end
          local params = {}
          if plist and trim(plist) ~= "" then
            params = splitArgs(plist)
          end
          local body, closed = {}, false
          while i <= #lines do
            local bl = lines[i]
            i = i + 1
            if trim(bl) == "%endmacro" then
              closed = true
              break
            end
            body[#body + 1] = bl
          end
          if not closed then
            fail(n, "%macro " .. name .. " is missing %endmacro")
          end
          if macros[name] then
            fail(n, "macro " .. name .. " is already defined")
          end
          macros[name] = { params = params, body = body }
        elseif dirName == "error" then
          fail(n, dirArg)
        else
          fail(n, "unknown directive %" .. dirName
            .. " (supported: %include %incbin %define %undef %macro %error)")
        end
      else
        local name, argStr = raw:match("^%s*([%a_][%w_]*)%s+(.*)$")
        if not name then
          name = raw:match("^%s*([%a_][%w_]*)%s*$")
          argStr = nil
        end
        local mac = name and macros[name]
        if mac then
          local args = argStr and splitArgs(argStr) or {}
          if #args ~= #mac.params then
            fail(n, "macro " .. name .. " takes " .. #mac.params
              .. " argument(s), got " .. #args)
          end
          local expanded = {}
          for _, bl in ipairs(mac.body) do
            expanded[#expanded + 1] = (bl:gsub("%%(%d?)", function(d)
              if d == "" then return "%" end
              local v = args[tonumber(d)]
              if v == nil then
                fail(n, "macro body uses %" .. d .. " but only "
                  .. #args .. " argument(s) given")
              end
              return v
            end))
          end
          processTable(expanded, depth + 1)
        else
          local s = raw
          for dn, dv in pairs(defines) do
            s = substWord(s, dn, dv)
          end
          out[#out + 1] = s
        end
      end
    end
  end

  local ok, err = pcall(processTable, splitLines(source), 0)
  if not ok then return nil, tostring(err) end
  return table.concat(out, "\n")
end

return pp
