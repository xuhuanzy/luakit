---#region lsp 专用的泛型定义区

--- 定义唯一父类. 通过`GetSuperClass<T>`获取该类型.
---@attribute define_super_class()

---@alias GetSuperClass<T> unknown

---#endregion

local setmetatable = setmetatable
local pairs = pairs
local ipairs = ipairs
local type = type
local rawset = rawset
local _errorHandler = error
local tableInsert = table.insert
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
---@field __name string 类名
---@field package __class__ string 实例持有. 类名字段
---@field package __deleted__ boolean? 实例持有. 是否已析构

---@class Class.Registry.ExtendInitData
---@field name string
---@field isSuper? boolean 是否是父类. 默认为 false.
---@field initControl? fun(self: any, super: (fun(...): Class.Type), ...) 初始化控制函数
---@field executor? fun(self: any, ...: any) 初始化执行器

---@class Class.Registry<T>
---@field package name         string 类名
---@field package kind         "class"|"trait" 类分类
---@field package supers?        string[] 记录了该类继承的类, 按顺序记录
---@field package superInitCall? fun(instance: T, super: (fun(...: ConstructorParameters<GetSuperClass<T>>...)), ...: ConstructorParameters<T>...) 指明在初始化时, 如何调用父类的构造函数.
---@field package extendsKeys  table<string, boolean> 记录该类已继承的所有字段
---@field package circularCheckDone? boolean 是否已完成循环继承检查
---@field package initCalls?    (fun(...)[])|false 初始化调用链. 为 false 时, 表示无需初始化.
---@field package firstSuperIsClass? boolean 第一个超类是否为 class.
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

---检查循环继承(仅检查一次并缓存结果)
---@package
---@param visited? table<string, boolean> 已访问的类名
function ClassRegistry:checkCircularInheritance(visited)
    if self.circularCheckDone then
        return
    end

    visited = visited or {}
    if visited[self.name] then
        error(('class %q has circular inheritance'):format(self.name))
    end

    visited[self.name] = true

    -- 递归检查所有父类和 trait
    if self.supers then
        for i = 1, #self.supers do
            local superName = self.supers[i]
            local parentConfig = getRegistry(superName)
            parentConfig:checkCircularInheritance(visited)
        end
    end

    visited[self.name] = nil
    self.circularCheckDone = true
end

-- 创建扩展相关的表
---@param self Class.Registry
local function createExtendsTables(self)
    if not self.supers then
        self.supers = {}
        self.extendsKeys = {}
    end
end

---清除当前类的缓存(在扩展关系变化时调用)
---@private
function ClassRegistry:clearCache()
    self.circularCheckDone = false
    self.initCalls = nil
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
---@param childMetadata Class.Registry 子类配置
---@param parentClass Class.Type 父类
---@param parentName string 父类名称
local function copyInheritedMembers(childClass, childMetadata, parentClass, parentName)
    local childExtendsKeys = childMetadata.extendsKeys

    -- 复制普通字段(跳过双下划线开头的元方法)
    for key, value in pairs(parentClass) do
        ---@cast value any
        -- 如果有多个父类, 那么相同字段将会以最后继承的为准.
        local canCopy = (not childClass[key] or childExtendsKeys[key]) and key:sub(1, 2) ~= '__'
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
            if not childClass.__getter[key] or childExtendsKeys[key] then
                childExtendsKeys[key] = true
                childClass.__getter[key] = getter
            end
        end

        -- 复制 setter 方法
        for key, setter in pairs(parentClass.__setter) do
            if not childClass.__setter[key] or childExtendsKeys[key] then
                childExtendsKeys[key] = true
                childClass.__setter[key] = setter
            end
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

    -- 延迟创建扩展相关的表
    createExtendsTables(self)

    -- 标记扩展关系
    for i = 1, #self.supers do
        local superName = self.supers[i]
        if superName == extendName then
            _errorHandler(('类 %q 声明了重复的超类 %q'):format(self.name, extendName))
        end
        if i > 1 then
            local registry = getRegistry(superName)
            if registry.kind == "class" then
                _errorHandler(('类 %q 只能继承一个超类, 无法继承 %q. 如果需要多继承请使用 trait.'):format(self.name, superName))
            end
            if extendClass.__init then
                local funcInfo = debugGetInfo(extendClass.__init, 'u')
                if funcInfo.nparams > 1 then
                    _errorHandler(('特质类 %q 的构造函数必须是无参的'):format(extendName))
                end
            end
        end
    end

    self.supers[#self.supers + 1] = extendName
    -- 复制父类的字段与 getter 和 setter
    copyInheritedMembers(currentClass, self, extendClass, extendName)
end

---@private
---@[lsp_optimization("delayed_definition")]
local runInit

--- 收集指定类的所有超类列表
---@param className string 当前类名
---@return string[]? superNames 超类名称列表
local function collectClassSupers(className)
    local classRegistry = getRegistry(className)
    local supers = classRegistry.supers
    if not supers then
        return nil
    end
    ---@type string[]
    local result = {}
    for i = 1, #supers do
        local superName = supers[i]
        local superSupers = collectClassSupers(superName)
        if superSupers then
            for _, superSuperName in ipairs(superSupers) do
                for j = 1, #result do
                    if result[j] == superSuperName then
                        goto continue
                    end
                end
                result[#result + 1] = superSuperName
                ::continue::
            end
        end
        for j = 1, #result do
            if result[j] == superName then
                goto continue
            end
        end
        result[#result + 1] = superName
        ::continue::
    end

    return result
end

--- 收集指定特质的所有超类列表
---@param traitName string
---@param visited table<string, boolean>
---@param result string[]
local function collectTraitSupers(traitName, visited, result)
    if visited[traitName] then
        return
    end
    visited[traitName] = true
    local registry = getRegistry(traitName)
    local supers = registry.supers
    if supers then
        for i = 1, #supers do
            collectTraitSupers(supers[i], visited, result)
        end
    end
    result[#result + 1] = traitName
end


--- 为对象创建初始化调用链
---@param obj table 要初始化的对象
---@param className string 类名
---@return false|fun(...)[]
local function createInitCalls(obj, className)
    local classRegistry = getRegistry(className)
    local supers = classRegistry.supers
    if not supers then
        return false
    end

    -- 检查多重继承限制：第一个 super 可以是 class，其余必须是 trait
    if #supers > 1 then
        for i = 2, #supers do
            local superRegistry = getRegistry(supers[i])
            if superRegistry.kind == "class" then
                _errorHandler(('类 %q 只能继承一个 class, 无法继承 %q. 如果需要多继承请使用 trait 混入.'):format(className,
                    supers[i]))
            end
        end
    end

    -- 构建初始化调用链
    ---@type fun(...: any)[]
    local initCalls = {}

    local visited = {}
    ---@type string[]
    local allSupers = {}
    local firstTraitIndex = 1

    -- 对于第一个超类, 我们需要额外处理, 因为他可能是`class`
    local firstSuperName = supers[1]
    if firstSuperName then
        local registry = getRegistry(firstSuperName)
        if registry.kind == "class" then
            firstTraitIndex = 2
            local firstSuperClass = collectClassSupers(firstSuperName)
            if firstSuperClass then
                for _, superName in ipairs(firstSuperClass) do
                    visited[superName] = true
                end
            end
            allSupers[#allSupers + 1] = firstSuperName
            visited[firstSuperName] = true
            if registry.superInitCall then
                initCalls[#initCalls + 1] = function(cobj, ...)
                    local firstCall = true
                    registry.superInitCall(cobj, function(super, ...)
                        if firstCall then
                            firstCall = false
                            runInit(cobj, registry.name, ...)
                        end
                    end, ...)
                end
            else
                initCalls[#initCalls + 1] = function(cobj, ...)
                    runInit(cobj, registry.name, ...)
                end
            end
        end
    end

    -- 对于其他, 我们认为其必须为`trait`
    for i = firstTraitIndex, #supers do
        local superName = supers[i]
        collectTraitSupers(superName, visited, allSupers)
    end


    for i = firstTraitIndex, #allSupers do
        local superName = allSupers[i]
        local class = _classTypeMap[superName]
        if class.__init then
            initCalls[#initCalls + 1] = class.__init
        end
    end


    return initCalls
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
        initCalls = createInitCalls(obj, className)
        if initCalls == false or #initCalls == 0 then
            registry.initCalls = false
            return
        end
        registry.initCalls = initCalls
    end
    for i = 1, #initCalls do
        initCalls[i](obj, ...)
    end
end

---@private
---@param obj table 要析构的对象
---@param className string 类名
local function runDel(obj, className)
    local currentClass = _classTypeMap[className]
    if not currentClass then
        return
    end

    local classConfig = getRegistry(className)


    -- 最后析构当前类
    if currentClass.__del then
        currentClass.__del(obj)
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

---@class Class.DeclareOptions<T: Class.Type>
---@field enableGetterAndSetter? boolean 启用 get 和 set 方法.
---@field extends? {[integer]: string|Class.Type} 扩展的类名或定义表集合, 例如: `extends = { 'A', B }`. 也可以使用更具体的 {@link ClassControl.extends}.
---@field superInitCall? fun(instance: T, super: (fun(...: ConstructorParameters<GetSuperClass<T>>...)), ...: ConstructorParameters<T>...)

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

        -- 设置父类
        if superName then
            local superClass = _classTypeMap[superName]
            if superClass then
                if class == superClass then
                    _errorHandler(('类 %q 不能继承自身'):format(name))
                end
                local superRegistry = getRegistry(superName)
                if superRegistry.kind == "trait" then
                    _errorHandler(('类 %q 不能继承特质 %q, 特质只能被混入. 请使用 extends 混入特质.'):format(name, superName))
                end
                if superClass.__init then
                    local funcInfo = debugGetInfo(superClass.__init, 'u')
                    if funcInfo.nparams > 1 and (not options or not options.superInitCall) then
                        _errorHandler(('父类 %q 具有有参构造函数, 但子类 %q 没有声明 superInitCall 字段, 请在子类中声明该字段.'):format(superName,
                            name))
                    end
                end
                if options and options.superInitCall then
                    registry.superInitCall = options.superInitCall
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

    -- 定义一个类. <br>
    -- 如果传入父类, 则父类的初始化函数必须要在子类内手动调用.
    ---@generic T, Super
    ---@[constructor("__init", "Class.Type")]
    ---@param name `T` 类名
    ---@[define_super_class()]
    ---@param super? `Super` | Class.Type 父类
    ---@param options? Class.DeclareOptions<T> 类的声明选项
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

    --- 定义一个特质. 特质是接口式可组合行为, 也可以被视为一种特殊的类.
    ---
    --- 一个类仅能继承一个父类, 但可以混入多个特质.
    ---@generic T, Super
    ---@[constructor("__init", "Class.Type")]
    ---@param name `T` 特质名称
    ---@param options? Class.DeclareOptions 特质声明选项
    ---@return T
    ---@return Class.Registry
    function ClassControl.trait(name, options)
        --[[ 特质只有混入, 没有具体的父类 ]]
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

        for i = 1, #config.supers do
            local extendName = config.supers[i]
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

    for childName, childConfig in pairs(_classRegistryMap) do
        if childConfig.supers and childConfig.supers[parentName] then
            local childClass = _classTypeMap[childName]
            if childClass then
                -- 复制父类的新方法到子类
                copyInheritedMembers(childClass, childConfig, parent, parentName)
            end
        end
    end
end

do
    --- 构造父类的上下文对象
    ---@class SuperContext<T: Class.Type>
    ---@field instance T 实例
    ---@field __init fun(instance: T, ...: ConstructorParameters<GetSuperClass<T>>...) 构造函数

    --- 超类
    ---@generic T: Class.Type
    ---@param instance T 类的实例
    ---@param ... ConstructorParameters<GetSuperClass<T>>... 构造函数参数
    function ClassControl.super(instance, ...)
        ---@cast instance Class.Type
        local name = instance.__class__
        if not name then
            _errorHandler('super() 调用失败, 没有找到实例的类名')
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
