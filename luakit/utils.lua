-- 通用工具函数

---@namespace Luakit

local Compat = require 'luakit.compat'
local stringFormat = string.format
local ioStdout = io.stdout
local tableInsert = table.insert
local tableConcat = table.concat
local stringFind = string.find
local stringSub = string.sub
local next = next
local mathType = math.type
local type = type
local tableUnpack = table.unpack

local isWindows = Compat.isWindows
---@type 'default'|'quit' |'error'
local errMode = 'default'

---@export
---@class Utils
local Utils = {}

-- 导入兼容性模块的成员到 Utils 模块
Utils.dirSeparator = Compat.dirSeparator
Utils.isWindows = Compat.isWindows
Utils.execute = Compat.execute


--- 使用格式化字符串打印任意数量的参数.
--- 输出将发送到 `io.stdout`.
---@param fmt string 格式化字符串. {@link string.format}
---@param ... string 格式化字符串的参数
function Utils.printf(fmt, ...)
    Utils.fprintf(ioStdout, fmt, ...)
end

--- 使用格式化字符串写入任意数量的参数到文件.
---@param file file 文件句柄.
---@param fmt string 格式化字符串. {@link string.format}
---@param ... string 格式化字符串的参数
function Utils.fprintf(file, fmt, ...)
    file:write(stringFormat(fmt, ...))
end

--- 根据条件返回两个值中的一个.
---@generic T, U
---@param cond boolean 条件
---@param value1 T 如果条件为真, 返回的值
---@param value2 U 如果条件为假, 返回的值
---@return T | U @ 返回的值
function Utils.choose(cond, value1, value2)
    if cond then
        return value1
    else
        return value2
    end
end

--- 将一组值转换为字符串
---@param t table 值列表
---@param temp table? 缓冲区
---@param tostr function? 可选的`tostring`函数, 默认使用内置的`tostring`函数
---@return table @ 转换后的缓冲区
function Utils.arrayTostring(t, temp, tostr)
    temp, tostr = temp or {}, tostr or tostring
    for i = 1, #t do
        ---@diagnostic disable-next-line: redundant-parameter
        temp[i] = tostr(t[i], i)
    end
    return temp
end

---@alias Utils.IsTypeGuard<T> T extends "nil" and nil or T extends "number" and number or T extends "string" and string
--- or T extends "boolean" and boolean or T extends "table" and table or T extends "function" and function
--- or T extends "thread" and thread or T extends "userdata" and userdata or T

--- 检查对象是否为指定类型.
---
--- 如果类型为字符串, 则使用type函数, 否则使用元表比较.
---@generic TP: std.type | table @ 约束泛型为`std.type`或`table`
---@param obj any 要检查的对象
---@param tp std.ConstTpl<TP> 要检查的类型. 可以是`std.type`或`table`
---@return TypeGuard<Utils.IsTypeGuard<TP>> @ 是否为指定类型
function Utils.isType(obj, tp)
    if type(tp) == 'string' then return type(obj) == tp end
    local mt = getmetatable(obj)
    return tp == mt
end

-- 一个带索引的迭代器，类似于`ipairs`, 但具有范围功能.
-- 这是一个基于索引的`nil`安全迭代器, 当列表中存在空缺时会返回`nil`. 为确保安全, 请确认表`t.n`中存储了长度信息.
---@param t table 要迭代的表
---@param i_start integer? 起始索引, 默认为`1`
---@param i_end integer? 结束索引, 默认为`t.n`或`#t`
---@param step integer? 步长, 默认为`1`
---@return fun(): integer, any
function Utils.npairs(t, i_start, i_end, step)
    step = step or 1
    if step == 0 then
        error("iterator step-size cannot be 0", 2)
    end
    local i = (i_start or 1) - step
    i_end = i_end or t.n or #t
    if step < 0 then
        return function()
            i = i + step
            if i < i_end then
                return nil
            end
            return i, t[i]
        end
    else
        return function()
            i = i + step
            if i > i_end then
                return nil
            end
            return i, t[i]
        end
    end
end

-- 一个迭代器, 用于迭代所有非整数键(与`ipairs`相反).
-- 它将跳过任何整数键, 因此负索引或带有空洞的数组也不会返回这些键(因此它返回的键比`ipairs`少一些).
--
-- 这个迭代器使用`pairs`实现, 因此任何可以使用`pairs`迭代的值都可以使用这个函数.
---@param t table 要迭代的表
---@return any key
---@return any value
function Utils.kpairs(t)
    local index
    return function()
        local value
        while true do
            index, value = next(t, index)
            if mathType(index) ~= "integer" then
                break
            end
        end
        return index, value
    end
end

--#region 错误处理

--- 断言所给参数确实属于正确类型
---@param n number 参数索引
---@param val any 参数值
---@param tp string 参数类型
---@param verify function? 可选的验证函数
---@param msg string? 可选的自定义消息
---@param lev integer? 可选的堆栈位置, 默认为`2`
---@return any @验证后的值
function Utils.assertArg(n, val, tp, verify, msg, lev)
    if type(val) ~= tp then
        error(("argument %d expected a '%s', got a '%s'"):format(n, tp, type(val)), lev or 2)
    end
    if verify and not verify(val) then
        error(("argument %d: '%s' %s"):format(n, val, msg), lev or 2)
    end
    return val
end

--- 断言参数是否为字符串.
---@param n number 参数索引
---@param val any 参数值
---@return any @ 验证后的值
function Utils.assertString(n, val)
    return Utils.assertArg(n, val, 'string', nil, nil, 3)
end

--- 控制错误策略.
---
--- 这是一个全局设置, 控制{@link Utils.raise}的行为:
--- - `'default'`: 返回`nil + error`
--- - `'error'`: 抛出 Lua 错误
--- - `'quit'`: 退出程序
---
---@param mode 'default'|'quit' |'error'
function Utils.onError(mode)
    errMode = mode
end

--- 用于返回错误. 其全局行为由 {@link Utils.onError} 控制.
---
--- 要使用此函数, 必须与`return`一起使用, 因为它可能返回`nil + error`.
---@param err string 错误字符串.
---@return any?, string @ 返回值和错误消息
function Utils.raise(err)
    if errMode == 'default' then
        return nil, err
    elseif errMode == 'quit' then
        ---@diagnostic disable-next-line: missing-return-value
        return Utils.quit(err)
    else
        error(err, 2)
    end
end

--#endregion 错误处理

--#region 文件操作

--- 读取文件内容并返回一个字符串.
---@param filename string 文件路径
---@param is_bin boolean 是否以二进制模式打开
---@return string? @ 文件内容
---@return string? @ 错误消息
function Utils.readfile(filename, is_bin)
    local mode = is_bin and 'b' or ''
    local f, open_err = io.open(filename, 'r' .. mode)
    if not f then
        ---@cast open_err -?
        return Utils.raise(open_err)
    end
    local res, read_err = f:read('*a')
    f:close()
    if not res then
        -- 在 io.open 中, 错误消息会有 "filename: " 前缀,
        -- 而在 file:read 中, 错误消息没有前缀, 需要手动添加.
        return Utils.raise(filename .. ": " .. read_err)
    end
    return res
end

--- 将一个字符串写入一个文件.
---@param filename string 文件路径
---@param str string 要写入的字符串
---@param is_bin boolean 是否以二进制模式打开
---@return boolean @ 是否成功
---@return string? @ 错误消息
function Utils.writefile(filename, str, is_bin)
    local mode = is_bin and 'b' or ''
    local f, err = io.open(filename, 'w' .. mode)
    if not f then
        ---@cast err -?
        return Utils.raise(err)
    end
    local ok, write_err = f:write(str)
    f:close()
    if not ok then
        -- 在 io.open 中, 错误消息会有 "filename: " 前缀,
        -- 而在 file:write 中, 错误消息没有前缀, 需要手动添加.
        return Utils.raise(filename .. ": " .. write_err)
    end
    return true
end

--- 读取文件内容并返回一个行列表.
---@param filename string 文件路径
---@return table @ 文件内容
---@return string? @ 错误消息
function Utils.readlines(filename)
    local f, err = io.open(filename, 'r')
    if not f then
        ---@cast err -?
        return Utils.raise(err)
    end
    local res = {}
    for line in f:lines() do
        tableInsert(res, line)
    end
    f:close()
    return res
end

--#endregion 文件操作

--#region 进程操作

--- 执行一个 shell 命令.
---@param cmd string 命令
---@param bin boolean 是否以二进制模式读取输出
---@return boolean @ 是否成功
---@return integer @ 实际返回代码
---@return string @ 标准输出
---@return string @ 错误输出
function Utils.executeex(cmd, bin)
    local outfile = os.tmpname()
    local errfile = os.tmpname()

    if isWindows and not outfile:find(':') then
        outfile = os.getenv('TEMP') .. outfile
        errfile = os.getenv('TEMP') .. errfile
    end
    cmd = cmd .. " > " .. Utils.quoteArg(outfile) .. " 2> " .. Utils.quoteArg(errfile)

    local success, retcode = Utils.execute(cmd)
    local outcontent = Utils.readfile(outfile, bin)
    local errcontent = Utils.readfile(errfile, bin)
    os.remove(outfile)
    os.remove(errfile)
    return success, retcode, (outcontent or ""), (errcontent or "")
end

--- 将一个命令参数进行转义和引用.
---@param argument string|string[] 要引用的参数, 如果传入字符串数组, 则将数组中的所有参数进行转义和引用.
---@return string @ 转义和引用后的参数
function Utils.quoteArg(argument)
    if type(argument) == "table" then
        -- 编码整个数组
        local r = {}
        for i, arg in ipairs(argument) do
            r[i] = Utils.quoteArg(arg)
        end
        return tableConcat(r, " ")
    end
    -- 只有单个参数
    if isWindows then
        -- 检测参数是否为空或包含空格、换行符、制表符、垂直制表符
        if argument == "" or argument:find('[ \f\t\v]') then
            -- 引用参数确保不会被错误解析为多个参数.
            -- 参考 CommandLineToArgvW Windows 函数的文档.
            argument = '"' .. argument:gsub([[(\*)"]], [[%1%1\"]]):gsub([[\+$]], "%0%0") .. '"'
        end

        -- os.execute() 使用 system() C 函数, 在 Windows 上将命令传递给 cmd.exe.
        -- 转义其特殊字符, 在 cmd 上使用 `^` 转义特殊字符以表示为字面量.
        return (argument:gsub('["^<>!|&%%]', "^%0"))
    else
        if argument == "" or argument:find('[^a-zA-Z0-9_@%+=:,./-]') then
            -- 在 POSIX 类似的系统上引用参数使用单引号.
            -- 如果存在单引号, 则需要转义单引号. 单引号不会处理任何特殊字符, 因此我们必须先结束单引号字符串, 再使用转义单引号, 最后再次打开单引号字符串.
            argument = "'" .. argument:gsub("'", [['\'']]) .. "'"
        end
        return argument
    end
end

--- 优雅地退出程序.
---@param msg string? 退出消息, 将发送到`stderr`, 将使用额外参数格式化
---@param code integer? 退出代码, 默认为`-1`
---@param ... string 额外参数用于消息的格式化
function Utils.quit(msg, code, ...)
    code = code or -1
    if msg then
        Utils.fprintf(io.stderr, msg, ...)
        io.stderr:write('\n')
    end
    os.exit(code, true)
end

--#endregion 进程操作

--#region 字符串操作

--- 转义任何 Lua 'magic' 字符串中的字符.
---
--- 即将 `-`, `.`, `+`, `[`, `]`, `(`, `)`, `$`, `^`, `%`, `?`, `*` 字符前面加上 `%` 字符.
---@param s string 输入字符串
---@return string @ 转义后的字符串
function Utils.escape(s)
    -- %1 表示捕获引用, %% 表示在字符串中插入一个 % 字符(因为`%`在替换字符串是特殊字符, 必须使用`%%`来表示一个%字符)
    return (s:gsub('[%-%.%+%[%]%(%)%$%^%%%?%*]', '%%%1'))
end

--- 将字符串按分隔符拆分成一个字符串列表.
---@param s string 输入字符串
---@param re string? 分隔符, 默认为`'%s+'`(一个或多个空格)
---@param plain boolean? 如果为`true`, 则不使用 Lua 模式匹配而是使用字符串查找
---@param n integer? 最大分割数, 如果超过则最后一个子字符串将保持不变
---@return table @ 返回一个类似列表的表
function Utils.split(s, re, plain, n)
    local i1, ls = 1, {}
    if not re then re = '%s+' end
    if re == '' then return { s } end
    while true do
        local i2, i3 = stringFind(s, re, i1, plain)
        if not i2 then
            local last = stringSub(s, i1)
            if last ~= '' then tableInsert(ls, last) end
            if #ls == 1 and ls[1] == '' then
                return {}
            else
                return ls
            end
        end
        ---@cast i2 -?
        tableInsert(ls, stringSub(s, i1, (i2 - 1) --[[@as integer]]))
        if n and #ls == n then
            ls[#ls] = stringSub(s, i1)
            return ls
        end
        ---@cast i3 -?
        i1 = i3 + 1
    end
    ---@diagnostic disable-next-line: missing-return
end

--- 将字符串分割成多个返回值.
---
--- 与 {@link Utils.split} 类似, 但返回多个子字符串而不是单个列表的子字符串.
---@param s string 输入字符串
---@param re string? 分隔符, 默认为`'%s+'`(一个或多个空格)
---@param plain boolean? 如果为`true`, 则不使用 Lua 模式匹配而是使用字符串查找
---@param n integer? 最大分割数, 如果超过则最后一个子字符串将保持不变
---@return ... string @ 返回多个子字符串
function Utils.splitv(s, re, plain, n)
    return tableUnpack(Utils.split(s, re, plain, n))
end

--#endregion 字符串操作

return Utils
