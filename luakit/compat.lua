-- 兼容性处理

---@namespace Luakit

---@class Compat
local Compat = {}

-- 当前平台的目录分隔符
Compat.dirSeparator = _G.package.config:sub(1, 1)

-- 是否为 Windows 平台
Compat.isWindows = Compat.dirSeparator == '\\'

--- 执行一个 shell 命令.
---@param cmd string 命令
---@return boolean status @ 是否成功
---@return integer code @ 实际返回代码
function Compat.execute(cmd)
    --[[
        Lua 5.1 与 LuaJIT 中, 返回值为一个状态码(整数).
        Lua 5.2+ 后返回三个值: 是否成功(`true`/`nil`), 类型('exit'|'signal'), 退出码.
    ]]
    local status, typ, exitcode = os.execute(cmd)
    if Compat.isWindows then
        return exitcode == 0, exitcode
    else
        return not not status, exitcode
    end
end

return Compat
