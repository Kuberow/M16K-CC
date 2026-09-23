-- m16k/asm.lua -- Two-pass assembler for the M16K.
--
-- Loaded with the install base path as its first vararg.
--   asm.assemble(source) -> org, bytes   (bytes = array of 0-255 values)
--                          or nil, errorMessage
--
-- Syntax:
--   label:                  defines a symbol
--   name = <expr>           constant symbol (evaluated immediately, so the
--                           expression may only use already-defined symbols)
--   org  <expr>             sets the load/run address; moving forward pads
--                           the image with zero bytes (the first org is the
--                           image's load address)
--   db   <item>, ...        bytes; items are numbers, expressions or "strings"
--   dw   <item>, ...        16-bit little-endian words
--   <MNEMONIC> <operand>    see isa.lua
--     LDA #expr             immediate
--     LDA expr              absolute
--     LDA (expr)            indirect (16-bit LE pointer stored at expr)
--     STA expr,X            indexed by X (also ,B)
--   ; comment               to end of line
--
-- Number literals: 123, 0x1F, 0b1010, 'A'
-- Expressions: numbers, symbols, + - * / % and parentheses

local base = ...
local isa = dofile(base .. "m16k/isa.lua")

local asm = {}

local function stripComment(line)
    local i = line:find(";", 1, true)
    if i then line = line:sub(1, i - 1) end
    return line
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Split on top-level commas, honouring "quotes" and (parentheses).
local function splitItems(s)
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

--------------------------------------------------------------------
-- Expression evaluator: numbers, symbols, + - * / and parentheses
--------------------------------------------------------------------

local function newEval(str, symbols, lineno)
    local pos = 1
    local n = #str

    local parseSum, parseTerm, parseUnary, parsePrimary

    local function skipWS()
        while pos <= n and str:sub(pos, pos):match("%s") do pos = pos + 1 end
    end

    local function peek()
        skipWS()
        return str:sub(pos, pos)
    end

    parsePrimary = function()
        local ch = peek()
        if ch == "" then
            error("line " .. lineno .. ": unexpected end of expression", 0)
        end
        if ch == "(" then
            pos = pos + 1
            local v = parseSum()
            if peek() ~= ")" then
                error("line " .. lineno .. ": missing ')'", 0)
            end
            pos = pos + 1
            return v
        end
        if ch == "'" then
            -- character literal 'x'
            local ch2 = str:sub(pos + 1, pos + 1)
            if str:sub(pos + 2, pos + 2) ~= "'" then
                error("line " .. lineno .. ": bad character literal", 0)
            end
            pos = pos + 3
            return ch2:byte()
        end
        local num = str:match("^0[xX]([0-9a-fA-F]+)", pos)
        if num then
            pos = pos + #num + 2
            return tonumber(num, 16)
        end
        num = str:match("^0[bB]([01]+)", pos)
        if num then
            pos = pos + #num + 2
            return tonumber(num, 2)
        end
        num = str:match("^%d+", pos)
        if num then
            pos = pos + #num
            return tonumber(num, 10)
        end
        local name = str:match("^[%a_][%w_]*", pos)
        if name then
            pos = pos + #name
            local v = symbols[name]
            if v == nil then
                error("line " .. lineno .. ": undefined symbol '" .. name .. "'", 0)
            end
            return v
        end
        error("line " .. lineno .. ": bad token in expression near '" .. ch .. "'", 0)
    end

    parseUnary = function()
        if peek() == "-" then
            pos = pos + 1
            return -parseUnary()
        end
        return parsePrimary()
    end

    parseTerm = function()
        local v = parseUnary()
        while true do
            local op = peek()
            if op == "*" or op == "/" or op == "%" then
                pos = pos + 1
                local rhs = parseUnary()
                if op == "*" then
                    v = v * rhs
                elseif op == "%" then
                    if rhs == 0 then
                        error("line " .. lineno .. ": modulo by zero", 0)
                    end
                    v = v % rhs
                else
                    if rhs == 0 then
                        error("line " .. lineno .. ": division by zero", 0)
                    end
                    v = math.floor(v / rhs)
                end
            else
                return v
            end
        end
    end

    parseSum = function()
        local v = parseTerm()
        while true do
            local op = peek()
            if op == "+" or op == "-" then
                pos = pos + 1
                local rhs = parseTerm()
                if op == "+" then v = v + rhs else v = v - rhs end
            else
                return v
            end
        end
    end

    local ok, val = pcall(parseSum)
    if not ok then
        error(tostring(val), 0)
    end
    skipWS()
    if pos <= n then
        error("line " .. lineno .. ": trailing junk in expression: '" .. str:sub(pos) .. "'", 0)
    end
    return val
end

local function evalExpr(str, symbols, lineno)
    return newEval(str, symbols, lineno)
end

--------------------------------------------------------------------
-- Instruction classification
--------------------------------------------------------------------

-- Returns kind, expr for an operand string ("" -> imp)
local function classify(operand)
    if operand == "" then return "imp", nil end
    if operand:sub(1, 1) == "#" then return "imm", trim(operand:sub(2)) end
    if operand:sub(1, 1) == "(" and operand:sub(-1) == ")" then
        return "ind", trim(operand:sub(2, -2))
    end
    local baseExpr, idx = operand:match("^(.-),%s*([xXbB])$")
    if baseExpr then
        return (idx:upper() == "X") and "ix" or "ib", trim(baseExpr)
    end
    return "abs", trim(operand)
end

-- Size in bytes of one statement (pass 1)
local function stmtSize(mn, operand, lineno)
    if mn == "ORG" then return 0 end
    if mn == "DB" then
        local total = 0
        for _, it in ipairs(splitItems(operand)) do
            if it:sub(1, 1) == '"' then
                if it:sub(-1) ~= '"' or #it < 2 then
                    error("line " .. lineno .. ": malformed string", 0)
                end
                total = total + #it - 2
            else
                total = total + 1
            end
        end
        return total
    end
    if mn == "DW" then return 2 * #splitItems(operand) end

    local def = isa.ops[mn]
    if not def then
        error("line " .. lineno .. ": unknown mnemonic '" .. mn .. "'", 0)
    end
    local kind = classify(operand)
    if not def[kind] then
        error("line " .. lineno .. ": '" .. mn .. "' does not accept " .. kind .. " operands", 0)
    end
    if kind == "imp" then return 1 end
    if kind == "imm" then return 2 end
    return 3 -- abs, ind, ix, ib
end

local function stringBytes(item, lineno)
    -- item includes surrounding quotes
    if item:sub(1, 1) ~= '"' or item:sub(-1) ~= '"' or #item < 2 then
        error("line " .. lineno .. ": malformed string " .. item, 0)
    end
    local s = item:sub(2, -2)
    local out = {}
    for i = 1, #s do out[#out + 1] = s:byte(i) end
    return out
end

--------------------------------------------------------------------
-- Main entry
--------------------------------------------------------------------

function asm.assemble(source)
    local symbols = {}
    local lines = {}

    -- lex
    local lineno = 0
    for raw in (source .. "\n"):gmatch("(.-)\n") do
        lineno = lineno + 1
        local line = trim(stripComment(raw))
        if line ~= "" then
            lines[#lines + 1] = { n = lineno, text = line }
        end
    end

    local org = 0x0200
    local firstOrgSet = false

    -- pass 1: symbol table + sizes
    local pc = org
    for _, L in ipairs(lines) do
        local line, n = L.text, L.n
        -- leading label(s)
        while true do
            local name, rest = line:match("^([%a_][%w_]*):%s*(.*)$")
            if not name then break end
            if symbols[name] ~= nil then
                return nil, "line " .. n .. ": duplicate label '" .. name .. "'"
            end
            symbols[name] = pc
            line = trim(rest)
            if line == "" then break end
        end
        if line ~= "" then
            -- constant symbol:  name = expr
            local eqName, eqExpr = line:match("^([%a_][%w_]*)%s*=%s*(.+)$")
            if eqName then
                if symbols[eqName] ~= nil then
                    return nil, "line " .. n .. ": duplicate symbol '" .. eqName .. "'"
                end
                local okE, val = pcall(evalExpr, eqExpr, symbols, n)
                if not okE then return nil, tostring(val) end
                symbols[eqName] = val
            else
                local mn, operand = line:match("^(%S+)%s*(.*)$")
                mn = mn:upper()
                operand = trim(operand or "")
                local ok, size = pcall(stmtSize, mn, operand, n)
                if not ok then return nil, tostring(size) end
                if mn == "ORG" then
                    local ok2, addr = pcall(evalExpr, operand, symbols, n)
                    if not ok2 then return nil, tostring(addr) end
                    pc = addr % 65536
                    if not firstOrgSet then
                        org = pc
                        firstOrgSet = true
                    end
                else
                    pc = pc + size
                end
            end
        end
    end

    -- pass 2: emit
    local out = {}
    local err
    pc = org
    local function emit(b)
        out[#out + 1] = b % 256
        pc = pc + 1
    end

    local okAll = true
    for _, L in ipairs(lines) do
        local line, n = L.text, L.n
        local ok, e = pcall(function()
            while true do
                local name, rest = line:match("^([%a_][%w_]*):%s*(.*)$")
                if not name then break end
                line = trim(rest)
                if line == "" then break end
            end
            if line == "" then return end

            -- constant symbol: consumed in pass 1, emits nothing
            if line:match("^[%a_][%w_]*%s*=%s*.+$") then return end

            local mn, operand = line:match("^(%S+)%s*(.*)$")
            mn = mn:upper()
            operand = trim(operand or "")

            if mn == "ORG" then
                local target = evalExpr(operand, symbols, n) % 65536
                if target < pc then
                    error(("line %d: org cannot move backwards (0x%04X < 0x%04X)")
                        :format(n, target, pc), 0)
                end
                while pc < target do emit(0) end
                return
            end
            if mn == "DB" then
                for _, it in ipairs(splitItems(operand)) do
                    if it:sub(1, 1) == '"' then
                        for _, b in ipairs(stringBytes(it, n)) do emit(b) end
                    else
                        emit(evalExpr(it, symbols, n))
                    end
                end
                return
            end
            if mn == "DW" then
                for _, it in ipairs(splitItems(operand)) do
                    local v = evalExpr(it, symbols, n) % 65536
                    emit(v % 256)
                    emit(math.floor(v / 256))
                end
                return
            end

            local kind, expr = classify(operand)
            local def = isa.ops[mn]
            if not def then error("line " .. n .. ": unknown mnemonic", 0) end
            local op = def[kind]
            if not op then error("line " .. n .. ": bad operand for " .. mn, 0) end

            emit(op)
            if kind == "imp" then return end
            local v = evalExpr(expr, symbols, n)
            if kind == "imm" then
                if v < -128 or v > 255 then
                    error("line " .. n .. ": immediate out of range (" .. v .. ")", 0)
                end
                emit(v % 256)
            else
                v = v % 65536
                emit(v % 256)
                emit(math.floor(v / 256))
            end
        end)
        if not ok then
            err = tostring(e)
            okAll = false
            break
        end
    end

    if not okAll then return nil, err end
    if #out == 0 then return nil, "nothing assembled" end
    return org, out
end

return asm
