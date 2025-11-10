local setmetatable = setmetatable
local pairs = pairs
local ipairs = ipairs
local type = type
local rawset = rawset
local _errorHandler = error
local debugGetInfo = debug.getinfo

---@export
---@class ClassControl
local ClassControl = {}

---记录了所有已声明的类
---@type table<string, Class.Type>
local _classTypeMap = {}

---@type table<string, Class.Registry<any>>
local _classRegistryMap = {}

---@class Class.Type
---@field public  __init?     fun(self: any, ...) 构造函数
---@field public  __del?      fun(self: any) 主动删除时调用的析构函数. gc 时并不会自动调用该函数.
---@field package __call      fun(self: any, ...): any 调用函数
---@field package __getter    table<string, fun(self: any): any> 所有获取器
---@field package __setter    table<string, fun(self: any, value: any): any> 所有设置器
---@field package __index     any
---@field package __newindex  any
---@field public  __name      string 类名
---@field package __class__   string 实例持有. 类名字段
---@field package __deleted__ boolean? 实例持有. 是否已析构

---@class Class.Registry<T>
---@field package name              string 类名
---@field package kind              "class"|"trait" 类分类
---@field package supers?           string[] 记录了该类继承的类, 按顺序记录
---@field package superInitCall?    fun(instance: T, ...) 经过处理后的可被直接调用的超类构造函数.
---@field package extendsKeys       table<string, boolean> 记录该类已继承的所有字段
---@field package initCalls?        (fun(...)[])|false 初始化调用链. 为 false 时, 表示无需初始化.
---@field package delCalls?         (fun(obj: any)[])|false 析构调用链. 为 false 时, 表示无需析构.
---@field package subclasses?       table<string, boolean> 记录直接子类
local ClassRegistry = {}

---获取指定类的注册表, 不存在则创建.
---@generic T
---@param name `T`|string 类名
---@return Class.Registry<T>
local function getRegistry(name)
    local config = _classRegistryMap[name]
    if not config then
        config = setmetatable({ name = name }, { __index = ClassRegistry })
        _classRegistryMap[name] = config
    end
    ---@diagnostic disable-next-line: return-type-mismatch
    return config
end


---启用 getter 和 setter 方法.
---@param class Class.Type 类
local function enableGetterAndSetter(class)
    if class.__getter then
        return
    end
    local __getter = {}
    local __setter = {}
    class.__getter = __getter
    class.__setter = __setter

    ---@package
    class.__index = function(self, key)
        local getter = __getter[key]
        if getter then
            return getter(self)
        end
        return class[key]
    end

    ---@package
    class.__newindex = function(self, key, value)
        local setter = __setter[key]
        if setter then
            setter(self, value)
        else
            rawset(self, key, value)
        end
    end
end


---复制父类字段到子类. 将跳过双下划线开头的元方法与一些特殊字段.
---@param childClass Class.Type 子类
---@param childRegistry Class.Registry 子类配置
---@param parentClass Class.Type 父类
---@param parentName string 父类名称
local function copyInheritedMembers(childClass, childRegistry, parentClass, parentName)
    local childExtendsKeys = childRegistry.extendsKeys

    -- 复制普通字段(跳过双下划线开头的元方法)
    for key, value in pairs(parentClass) do
        ---@cast value any
        -- 如果有多个父类, 那么相同字段将会以最后继承的为准.
        local canCopy = (childClass[key] == nil or childExtendsKeys[key]) and key:sub(1, 2) ~= '__'
        if canCopy then
            childExtendsKeys[key] = true
            childClass[key] = value
        end
    end

    -- 如果父类有 getter 和 setter, 且子类没有, 则为子类启用 getter 和 setter
    if parentClass.__getter then
        if not childClass.__getter then
            enableGetterAndSetter(childClass)
        end

        -- 复制 getter 方法
        for key, getter in pairs(parentClass.__getter) do
            if childClass.__getter[key] == nil or childExtendsKeys[key] then
                childExtendsKeys[key] = true
                childClass.__getter[key] = getter
            end
        end

        -- 复制 setter 方法
        for key, setter in pairs(parentClass.__setter) do
            if childClass.__setter[key] == nil or childExtendsKeys[key] then
                childExtendsKeys[key] = true
                childClass.__setter[key] = setter
            end
        end
    end
end

---清除指定类的初始化缓存
---@param className string
---@param visited table<string, boolean>
local function clearInitCache(className, visited)
    if visited[className] then
        return
    end
    visited[className] = true

    local registry = _classRegistryMap[className]
    if registry then
        ---清除当前类的缓存
        registry.initCalls = nil
        registry.delCalls = nil
    end

    if registry and registry.subclasses then
        for childName in pairs(registry.subclasses) do
            clearInitCache(childName, visited)
        end
    end
end

---扩展一个类.
---@package
---@generic Extends
---@param extendName `Extends` 扩展名称
function ClassRegistry:extends(extendName)
    local currentClass = _classTypeMap[self.name]
    local extendClass = _classTypeMap[extendName]

    if not extendClass then
        _errorHandler(('extends class %q not found'):format(extendName))
    end
    self.supers = self.supers or {}
    self.extendsKeys = self.extendsKeys or {}

    -- 标记扩展关系
    for i = 1, #self.supers do
        local superName = self.supers[i]
        if superName == extendName then
            _errorHandler(('类 %q 声明了重复的超类 %q'):format(self.name, extendName))
        end
        if i > 1 then
            local registry = getRegistry(superName)
            if registry.kind == "class" then
                _errorHandler(('类 %q 已继承 class %q, 无法再继承 class %q；若需要额外复用行为，请将后者声明为 trait 并通过 extends 混入。'):format(
                    self.name, superName, extendName))
            end
        end
    end
    local extendRegistry = getRegistry(extendName)
    if extendRegistry.kind == "trait" and extendClass.__init then
        local funcInfo = debugGetInfo(extendClass.__init, 'u')
        if funcInfo.nparams > 1 then
            _errorHandler(('trait %q 的 __init 不得接收参数；混入特质时不会向其传递构造参数，请移除或改成可选参数。'):format(extendName))
        end
    end
    extendRegistry.subclasses = extendRegistry.subclasses or {}

    self.supers[#self.supers + 1] = extendName
    extendRegistry.subclasses[self.name] = true
    -- 复制父类的字段与 getter 和 setter
    copyInheritedMembers(currentClass, self, extendClass, extendName)
    clearInitCache(self.name, {})
end

---@[lsp_optimization("delayed_definition")]
local runInit

do
    --- 收集指定类的所有超类列表
    ---@param className string 当前类名
    ---@param visiting? table<string, boolean>
    ---@return table<string, boolean>? superNames 超类名称列表
    local function getClassSupers(className, visiting)
        visiting = visiting or {}
        if visiting[className] then
            _errorHandler(('类 %q 存在循环继承, 请检查 extends 配置.'):format(className))
        end
        visiting[className] = true

        local supers = getRegistry(className).supers
        if not supers then
            visiting[className] = nil
            return nil
        end
        ---@type table<string, boolean>
        local result = {}
        for i = 1, #supers do
            local superName = supers[i]
            local superSupers = getClassSupers(superName, visiting)
            if superSupers then
                for superSuperName, _ in pairs(superSupers) do
                    result[superSuperName] = true
                end
            end
            result[superName] = true
        end
        visiting[className] = nil
        return result
    end

    --- 为对象创建初始化调用链
    ---@param className string 类名
    ---@param initCalls fun(...)[]
    ---@param visited table<string, boolean>
    ---@param building table<string, boolean>
    local function createInitCalls(className, initCalls, visited, building)
        building = building or {}
        if building[className] then
            _errorHandler(('类 %q 存在循环继承, 请检查 extends 配置.'):format(className))
        end
        if visited[className] then
            return
        end
        building[className] = true
        visited[className] = true
        local class = _classTypeMap[className]
        local classRegistry = getRegistry(className)
        local supers = classRegistry.supers
        if not supers then
            if class.__init then
                initCalls[#initCalls + 1] = class.__init
            end
            building[className] = nil
            return
        end

        for i = 1, #supers do
            local superName = supers[i]
            local superRegistry = getRegistry(superName)
            -- 如果存在父类的显式调用, 则使用该调用
            if i == 1 and superRegistry.kind == "class" and classRegistry.superInitCall then
                initCalls[#initCalls + 1] = classRegistry.superInitCall
                -- 标记该超类链上的所有类为已访问
                local firstSuperClass = getClassSupers(superName)
                if firstSuperClass then
                    for name, _ in pairs(firstSuperClass) do
                        visited[name] = true
                    end
                end
                visited[superName] = true
            else
                if i > 1 and superRegistry.kind == "class" then
                    _errorHandler(('class %q 需要作为 `trait` 混入到类 %q'):format(superName, className))
                end
                -- 否则递归收集
                createInitCalls(superName, initCalls, visited, building)
            end
        end

        if class.__init then
            initCalls[#initCalls + 1] = class.__init
        end
        building[className] = nil
    end

    ---@param obj table 要初始化的对象
    ---@param className string 类名
    ---@param ... any 构造函数参数
    runInit = function(obj, className, ...)
        local registry = getRegistry(className)
        local initCalls = registry.initCalls
        if initCalls == false then
            return
        end
        if not initCalls then
            initCalls = {}
            createInitCalls(className, initCalls, {}, {})
            if #initCalls == 0 then
                registry.initCalls = false
                return
            end
            registry.initCalls = initCalls
        end

        ---@cast initCalls fun(...)[]
        for i = 1, #initCalls do
            initCalls[i](obj, ...)
        end
    end
end

---@[lsp_optimization("delayed_definition")]
local runDel

do
    --- 构建指定类的析构调用链
    ---@param className string
    ---@param delCalls fun(obj: any)[]
    ---@param visited table<string, boolean>
    local function buildDelCalls(className, delCalls, visited)
        if visited[className] then
            return
        end
        visited[className] = true

        local class = _classTypeMap[className]
        if not class then
            return
        end

        if class.__del then
            delCalls[#delCalls + 1] = class.__del
        end

        local supers = getRegistry(className).supers
        if not supers then
            return
        end

        for i = #supers, 1, -1 do
            buildDelCalls(supers[i], delCalls, visited)
        end
    end

    ---@param obj table 要析构的对象
    ---@param className string 类名
    runDel = function(obj, className)
        if not _classTypeMap[className] then
            return
        end

        local registry = getRegistry(className)
        local delCalls = registry.delCalls
        if delCalls == false then
            return
        end
        if not delCalls then
            delCalls = {}
            buildDelCalls(className, delCalls, {})
            if #delCalls == 0 then
                registry.delCalls = false
                return
            end
            registry.delCalls = delCalls
        end
        ---@cast delCalls fun(obj: any)[]
        for i = 1, #delCalls do
            delCalls[i](obj)
        end
    end
end

---实例化一个类.
---@generic T
---@param name `T`|T 类名
---@param ... ConstructorParameters<T>... 构造函数参数
---@return T
function ClassControl.new(name, ...)
    name = name.__name or name ---@cast name -table
    local class = _classTypeMap[name]
    if not class then
        _errorHandler(('class %q not found'):format(name))
    end

    local obj = setmetatable({ __class__ = name }, class)
    return obj(...)
end

---@class Class.DeclareOptions<T: Class.Type, Super: Class.Type>
---@field enableGetterAndSetter? boolean 启用 get 和 set 方法.
---@field extends? {[integer]: string|Class.Type} 扩展的类名或定义表集合, 例如: `extends = { 'A', B }`. 也可以使用更具体的 {@link ClassControl.extends}.
---@field superInitCall? fun(instance: T, super: (fun(...: ConstructorParameters<Super>...)), ...: ConstructorParameters<T>...)

do
    ---@generic T, Super
    ---@param name `T` 类名
    ---@param superName? `Super` 父类
    ---@param classKind "class"|"trait" 类分类
    ---@param options? Class.DeclareOptions 类的声明选项
    ---@return T
    ---@return Class.Registry
    local function define(name, superName, classKind, options)
        local registry = getRegistry(name)
        -- 如果已声明, 则返回已声明的类和配置.
        -- 这会导致热重载时仍持有旧的类和配置, 但重声明方法在绝大多数的情况下已经足够使用, 而完全修改的代价过于巨大.
        if _classTypeMap[name] then
            return _classTypeMap[name], registry
        end
        registry.kind = classKind

        ---@diagnostic disable-next-line: missing-fields
        ---@type Class.Type
        local class = {
            __name = name,
            ---@package
            __call = function(self, ...)
                runInit(self, name, ...)
                return self
            end,
        }

        if options and options.enableGetterAndSetter then
            enableGetterAndSetter(class)
        else
            class.__index = class
        end

        _classTypeMap[name] = class

        -- 设置父类型
        if superName then
            local superClass = _classTypeMap[superName]
            if superClass then
                if class == superClass then
                    _errorHandler(('类 %q 不能继承自身'):format(name))
                end
                local superRegistry = getRegistry(superName)
                if superClass.__init then
                    local funcInfo = debugGetInfo(superClass.__init, 'u')
                    if funcInfo.nparams > 1 and (not options or not options.superInitCall) then
                        _errorHandler(('父类型 %q 具有有参构造函数, 但 options 没有声明 superInitCall 字段')
                            :format(superName, name))
                    end
                end
                if options then
                    local superInitCall = options.superInitCall
                    if superInitCall then
                        -- 将传入的 superInitCall 包装为指定格式
                        registry.superInitCall = function(cobj, ...)
                            local firstCall = true
                            superInitCall(cobj, function(...)
                                if firstCall then
                                    firstCall = false
                                    runInit(cobj, superRegistry.name, ...)
                                end
                            end, ...)
                        end
                    end
                end
                registry:extends(superName)
            else
                _errorHandler(('super class %q not found'):format(superName))
            end
        end

        -- 设置扩展类
        if options and options.extends then
            for _, extendsName in ipairs(options.extends) do
                registry:extends(extendsName.__name or extendsName --[[@as string]])
            end
        end

        return class, registry
    end

    -- 定义一个类
    ---@generic T, Super
    ---@[constructor("__init", "Class.Type")]
    ---@param name `T` 类名
    ---@param super? `Super` | Class.Type 父类
    ---@param options? Class.DeclareOptions<T, Super> 类的声明选项
    ---@return T
    ---@return Class.Registry
    function ClassControl.class(name, super, options)
        local superName
        if super then
            if type(super) == 'string' then
                superName = super
            else
                superName = super.__name
            end
        end
        return define(name, superName, "class", options)
    end

    --- 定义一个特质. 特质是接口式可组合行为.
    ---
    --- 一个类仅能继承一个`class`, 但可以混入多个`trait`.
    ---@generic T
    ---@[constructor("__init", "Class.Type")]
    ---@param name `T` 特质名称
    ---@param options? Class.DeclareOptions 特质声明选项
    ---@return T
    ---@return Class.Registry
    function ClassControl.trait(name, options)
        return define(name, nil, "trait", options)
    end
end

---析构一个实例
---@param obj table
function ClassControl.delete(obj)
    if obj.__deleted__ then
        return
    end
    obj.__deleted__ = true
    local name = obj.__class__
    if not name then
        _errorHandler('can not delete undeclared class : ' .. tostring(obj))
    end

    runDel(obj, name)
end

--- 为指定 类/特质 混入一个特质.
---@generic Class
---@generic Extends
---@param name `Class`|Class.Type 类名
---@param extendsName `Extends`|Class.Type 扩展类名
function ClassControl.extends(name, extendsName)
    name = name.__name or name ---@cast name string
    extendsName = extendsName.__name or extendsName ---@cast extendsName string
    getRegistry(name):extends(extendsName)
end

do
    ---@param className string
    ---@param targetName string
    ---@param visited table<string, boolean>
    ---@return boolean
    local function isSubclassOf(className, targetName, visited)
        if className == targetName then
            return true
        end
        if visited[className] then
            return false
        end
        visited[className] = true

        local config = _classRegistryMap[className]
        if not config or not config.supers then
            return false
        end

        for _, extendName in ipairs(config.supers) do
            if isSubclassOf(extendName, targetName, visited) then
                return true
            end
        end

        return false
    end

    --- 检查对象是否为指定类或其子类的实例.
    ---@generic T: Class.Type
    ---@param obj Class.Type 要判断的实例.
    ---@param targetName `T`|Class.Type 目标类名或目标类对象. 可以是类名或类对象.
    ---@return boolean
    function ClassControl.instanceof(obj, targetName)
        if type(obj) ~= 'table' or (not obj.__class__) then
            return false
        end

        if type(targetName) == 'table' then
            if targetName.__name then
                targetName = targetName.__name
            else
                error(('class %q not found'):format(targetName))
            end
        end

        return isSubclassOf(obj.__class__, targetName, {})
    end
end

do
    ---刷新父类新增字段到子类, 仅复制子类不存在的条目
    ---@param childClass Class.Type
    ---@param childRegistry Class.Registry
    ---@param parentClass Class.Type
    local function copyMissingParentMembers(childClass, childRegistry, parentClass)
        childRegistry.extendsKeys = childRegistry.extendsKeys or {}
        for key, value in pairs(parentClass) do
            if key:sub(1, 2) ~= '__' and childClass[key] == nil then
                childRegistry.extendsKeys[key] = true
                childClass[key] = value
            end
        end
    end

    -- 刷新指定父类的所有子类继承关系. <br>
    -- 只有在完全确定所有子类不会发生变化时才应该调用此函数.
    ---@param parentClass string|Class.Type 父类名称或父类对象
    function ClassControl.refreshInheritance(parentClass)
        local parentName = parentClass.__name or parentClass
        if type(parentName) ~= 'string' then
            _errorHandler('`parentClass` must be a class or class name')
            return
        end

        local parent = _classTypeMap[parentName]
        if not parent then
            _errorHandler(('parent class %q not found'):format(parentName))
            return
        end

        local parentRegistry = getRegistry(parentName)
        if not parentRegistry.subclasses then
            return
        end

        for childName in pairs(parentRegistry.subclasses) do
            local childClass = _classTypeMap[childName]
            local childRegistry = getRegistry(childName)
            if childClass and childRegistry then
                copyMissingParentMembers(childClass, childRegistry, parent)
            end
        end
    end
end


---设置错误处理函数
---@param errorHandler fun(msg: string)
function ClassControl.setErrorHandler(errorHandler)
    _errorHandler = errorHandler
end

---获取一个类
---@generic T
---@param name `T`
---@return Class.Type
function ClassControl.get(name)
    return _classTypeMap[name]
end

---判断一个实例是否有效
---@param obj table
---@return boolean
function ClassControl.isValid(obj)
    if not obj.__class__ then
        return false
    end
    return not obj.__deleted__
end

---获取类的名称
---@param obj any
---@return string?
function ClassControl.type(obj)
    if type(obj) ~= 'table' then
        return nil
    end
    return obj.__class__
end

ClassControl.getRegistry = getRegistry
return ClassControl
