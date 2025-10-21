---@namespace Luakit

local setmetatable = setmetatable
local pairs = pairs
local ipairs = ipairs
local type = type
local rawset = rawset
local _errorHandler = error
local tableInsert = table.insert
local debugGetInfo = debug.getinfo

-- 所有类的基类
---@class Object
---@field __name string 类名
---@field package __class__ string 实例持有的类名字段, 用于区分是否为实例
---@field package __deleted__ boolean? 是否已析构

---@export
---@class ClassControl
local ClassControl = {}

---记录了所有已声明的类
---@type table<string, Class.Definition>
local _classMap = {}

---为已有构造函数创建的类型别名
---@type table<string, function>
local _aliasMap = {}

---@type table<string, Class.Metadata>
local _classConfigMap = {}

---@class Class.Definition
---@field public  __init?     fun(self: any, ...) 构造函数
---@field public  __del?      fun(self: any) 析构函数
---@field package __call      fun(self: any, ...): any 调用函数
---@field package __name      string 类名
---@field package __getter    table<string, fun(self: any): any> 所有获取器
---@field package __setter    table<string, fun(self: any, value: any): any> 所有设置器
---@field package __index     any
---@field package __newindex  any


---@class Class.Metadata.ExtendInitData
---@field name string
---@field isSuper? boolean 是否是父类. 默认为 false.
---@field initControl? fun(self: any, super: (fun(...): Class.Definition), ...) 初始化控制函数
---@field executor? fun(self: any, ...: any) 初始化执行器

---@class Class.Metadata
---@field private name         string 类名
---@field package extendsMap   table<string, boolean> 记录了该类扩展的类(包含父类)
---@field package extendsInitDatas Class.Metadata.ExtendInitData[] 记录了所有扩展的类的初始化信息
---@field package extendsKeys  table<string, boolean> 记录该类已继承的所有字段
---@field package superClass?  Class.Definition 记录了父类. 父类是唯一的, 但可以存在多个扩展类(包含了父类). 如果父类有构造函数, 则必须由子类显式调用.
---@field package initCalls?   false|fun(...)[] 初始化函数调用链, 如果为`false`则表示无需初始化, 为`nil`则表示还未计算
---@field package circularCheckDone? boolean 是否已完成循环继承检查
local ClassMetadata = {}

---获取指定类的元数据, 不存在则创建.
---@param name string
---@return Class.Metadata
local function getMetadata(name)
    local config = _classConfigMap[name]
    if not config then
        config = setmetatable({ name = name }, { __index = ClassMetadata })
        _classConfigMap[name] = config
    end
    return config
end

---检查循环继承(仅检查一次并缓存结果)
---@package
---@param visited? table<string, boolean> 已访问的类名
function ClassMetadata:checkCircularInheritance(visited)
    if self.circularCheckDone then
        return
    end

    visited = visited or {}
    if visited[self.name] then
        error(('class %q has circular inheritance'):format(self.name))
    end

    visited[self.name] = true

    -- 递归检查所有扩展的类
    if self.extendsInitDatas then
        for _, initData in ipairs(self.extendsInitDatas) do
            local parentConfig = getMetadata(initData.name)
            parentConfig:checkCircularInheritance(visited)
        end
    end

    visited[self.name] = nil
    self.circularCheckDone = true
end

-- 创建扩展相关的表
---@param self Class.Metadata
local function createExtendsTables(self)
    if not self.extendsMap then
        self.extendsMap = {}
        self.extendsInitDatas = {}
        self.extendsKeys = {}
    end
end

---清除当前类的缓存(在扩展关系变化时调用)
---@private
function ClassMetadata:clearCache()
    self.circularCheckDone = false
    self.initCalls = nil
    ClassMetadata.increaseInheritanceVersion()
end

---启用 getter 和 setter 方法.
---@param class Class.Definition 类
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
---@param childClass Class.Definition 子类
---@param childMetadata Class.Metadata 子类配置
---@param parentClass Class.Definition 父类
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
---@param extendsInit? fun(self: self, super: Extends) 扩展初始化控制函数. 第二个参数是扩展初始化包装函数, 调用后将执行扩展类的初始化函数, 然后返回扩展类的配置.
function ClassMetadata:extends(extendName, extendsInit)
    local currentClass = _classMap[self.name]
    local extendClass = _classMap[extendName]

    -- 验证父类存在性
    if not extendClass then
        _errorHandler(('class %q not found'):format(extendName))
    end

    -- 验证初始化函数类型
    if type(extendsInit) ~= 'nil' and type(extendsInit) ~= 'function' then
        _errorHandler('extendsInit must be nil or function')
    end

    local isSuper = self.superClass and self.superClass.__name == extendName

    -- 延迟创建扩展相关的表
    createExtendsTables(self)

    local needClearCache = false

    -- 标记扩展关系
    if not self.extendsMap[extendName] then
        self.extendsMap[extendName] = true
        needClearCache = true
    end

    -- 复制父类的字段与 getter 和 setter
    copyInheritedMembers(currentClass, self, extendClass, extendName)

    -- 记录父类的初始化方法
    do
        local existing ---@type Class.Metadata.ExtendInitData?
        for i = 1, #self.extendsInitDatas do
            local initData = self.extendsInitDatas[i]
            if initData.name == extendName then
                existing = initData
                break
            end
        end

        local superFlag = isSuper == true and true or nil

        if existing then
            local updated
            if existing.initControl ~= extendsInit then
                existing.initControl = extendsInit
                existing.executor = nil
                updated = true
            end
            if existing.isSuper ~= superFlag then
                existing.isSuper = superFlag
                updated = true
            end
            if updated then
                needClearCache = true
            end
        else
            ---@type Class.Metadata.ExtendInitData
            local initData = {
                initControl = extendsInit,
                name = extendName,
                isSuper = superFlag,
                executor = nil,
            }
            tableInsert(self.extendsInitDatas, initData)
            needClearCache = true
        end
    end

    if needClearCache then
        -- 仅在实际发生变动时清理缓存, 避免重复构建
        self:clearCache()
    end

    -- 检查是否需要显式初始化
    if not extendsInit then
        -- 如果父类没有构造函数, 则无需处理
        if not extendClass.__init then
            return
        end

        -- 父类的初始化函数必须由子类显式调用
        if self.superClass and self.superClass.__name == extendName then
            return
        end

        -- 获取父类构造函数的参数数量
        local funcInfo = debugGetInfo(extendClass.__init, 'u')
        if funcInfo.nparams <= 1 then -- 1 是 self 参数
            return
        end

        -- 如果没有传入初始化函数且父类有显式参数的构造函数, 则需要显式初始化
        _errorHandler(('must call super for extends "%s"'):format(extendName))
    end
end

---@private
---@param obj table 要初始化的对象
---@param className string 类名
---@param ... any 构造函数参数
local function runInit(obj, className, ...)
    local classConfig = getMetadata(className)
    local initCalls = classConfig.initCalls

    -- 如果已确定无需初始化, 直接返回
    if initCalls == false then
        return
    end

    -- 如果还没有缓存初始化调用链, 则构建它
    if not initCalls then
        -- 预先检查循环继承(仅检查一次)
        classConfig:checkCircularInheritance()

        -- 收集所有需要的初始化函数
        initCalls = {}
        local seen = {}

        local function collectInitCalls(currentClassName)
            ---@cast initCalls - nil
            if seen[currentClassName] then
                return
            end
            seen[currentClassName] = true

            local currentClass = _classMap[currentClassName]
            local currentConfig = getMetadata(currentClassName)

            -- 先收集扩展类的初始化控制函数, 如果存在控制函数, 那么将由控制函数主导目标扩展类的初始化流程,
            -- 否则直接调用扩展类的初始化函数`__init`
            if currentConfig.extendsInitDatas then
                for _, extendInitData in ipairs(currentConfig.extendsInitDatas) do
                    if extendInitData.initControl then
                        local executor = extendInitData.executor
                        if not executor then
                            ---@cast extendInitData.initControl - nil
                            executor = function(instance, ...)
                                local firstCall = true -- 避免重复调用父类初始化函数
                                extendInitData.initControl(instance, function(...)
                                    if firstCall then
                                        firstCall = false
                                        runInit(instance, extendInitData.name, ...)
                                    end
                                    return _classMap[extendInitData.name]
                                end, ...)
                            end
                            extendInitData.executor = executor
                        end
                        initCalls[#initCalls + 1] = executor
                    elseif extendInitData.isSuper then
                        -- 不做任何处理, 父类初始化必须由子类显式调用
                    else
                        -- 该扩展类没有自定义的初始化控制函数, 递归收集
                        collectInitCalls(extendInitData.name)
                    end
                end
            end

            -- 最后收集当前类自己的初始化函数
            if currentClass.__init then
                initCalls[#initCalls + 1] = currentClass.__init
            end
        end

        collectInitCalls(className)

        -- 缓存结果
        if #initCalls == 0 then
            classConfig.initCalls = false
            --无需初始化, 直接返回
            return
        else
            classConfig.initCalls = initCalls
            initCalls = classConfig.initCalls
        end
    end

    ---@cast initCalls fun(...: any)[]

    -- 执行所有初始化函数
    for i = 1, #initCalls do
        initCalls[i](obj, ...)
    end
end

---@private
---@param obj table 要析构的对象
---@param className string 类名
local function runDel(obj, className)
    local currentClass = _classMap[className]
    if not currentClass then
        return
    end

    local classConfig = getMetadata(className)

    -- 先析构所有扩展的类
    if classConfig.extendsInitDatas then
        for _, callData in ipairs(classConfig.extendsInitDatas) do
            runDel(obj, callData.name)
        end
    end

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
    local class = _classMap[name]
    if not class then
        local aliasCreator = _aliasMap[name]
        if aliasCreator then
            return function(...)
                local instance = aliasCreator(...)
                instance.__class__ = name
                return instance
            end
        end
        _errorHandler(('class %q not found'):format(name))
    end

    local obj = setmetatable({ __class__ = name }, class)
    return obj(...)
end

---@class Class.DeclareOptions
---@field enableGetterAndSetter? boolean 启用 get 和 set 方法.
---@field super? string|Object|Class.DeclareOptions 父类的名称或定义表. 需要在初始化时显式调用父类初始化方法进行初始化.
---@field extends? {[integer]: string|Object} 扩展的类名或定义表集合, 例如: `extends = { 'A', B }`. 也可以使用更具体的 {@link ClassControl.extends}.

-- 定义一个类. <br>
-- 如果传入父类, 则父类的初始化函数必须要在子类内手动调用.
---@generic T, Super
---@[constructor("__init", "Luakit.Object")]
---@param name `T` 类名
---@param superOrOptions? `Super` | Object | Class.DeclareOptions 类的声明选项, 当提供字符串或定义表时默认为`super`
---@return T
---@return Class.Metadata
function ClassControl.declare(name, superOrOptions)
    local metadata = getMetadata(name)
    if _classMap[name] then -- 如果已声明, 则返回已声明的类和配置
        return _classMap[name], metadata
    end

    local options = superOrOptions or {}
    if type(superOrOptions) == 'string' then
        -- 如果是字符串, 当作父类名处理 (快捷方式)
        options = { super = superOrOptions }
    elseif type(superOrOptions) == 'table' and superOrOptions.__name then
        options = { super = superOrOptions.__name }
    end
    ---@cast options Class.DeclareOptions

    ---@class (constructor) Class.Definition
    local class = {
        __name = name,
        ---@package
        __call = function(self, ...)
            runInit(self, name, ...)
            return self
        end,
    }

    if options.enableGetterAndSetter then
        enableGetterAndSetter(class)
    else
        class.__index = class
    end

    _classMap[name] = class

    -- 设置父类
    if options.super then
        local superClass = _classMap[options.super]
            or _classMap[ --[[@cast options.super Object ]] options.super.__name ]
        if superClass then
            if class == superClass then
                _errorHandler(('class %q can not inherit itself'):format(name))
            end
            metadata.superClass = superClass
            metadata:extends(superClass.__name)
        else
            _errorHandler(('super class %q not found'):format(options.super))
        end
    end

    -- 设置扩展类
    if options.extends then
        for _, extendsName in ipairs(options.extends) do
            metadata:extends(extendsName.__name or extendsName --[[@as string]])
        end
    end

    return class, metadata
end

---为非`Class.declare`声明的类创建类型别名, 使其可以被`Class.new`实例化.
---@param name string 类型别名
---@param creator function 构造函数, 该函数没有`self`参数, 且必须返回一个实例.
function ClassControl.alias(name, creator)
    _aliasMap[name] = creator
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

---扩展一个类. <br>
---如果传入`extendsInitControl`参数, 则会由该函数控制父类的初始化. 并且你必须调用第二个参数`super()`才能触发父类的初始化流程. <br>
---如果未传入`extendsInitControl`参数, 则会递归寻找父类链上的具有初始化函数的类尝试初始化.
---@generic Class
---@generic Extends
---@param name `Class`|Object 类名
---@param extendsName `Extends`|Object 扩展类名
---@param extendsInitControl? fun(self: Class, super: Extends, ...) 扩展初始化控制函数. 第二个参数是父类初始化包装函数, 调用后将执行父类的初始化函数, 然后返回父类的配置.
function ClassControl.extends(name, extendsName, extendsInitControl)
    name = name.__name or name ---@cast name string
    extendsName = extendsName.__name or extendsName ---@cast extendsName string
    getMetadata(name):extends(extendsName, extendsInitControl)
end

do
    ---@type table<string, { version: integer, chain: table<string, boolean> }>
    local inheritanceChains = {}
    local inheritanceVersion = 0

    ---@param className string
    ---@return table<string, boolean>
    local function buildInheritanceChain(className)
        local entry = inheritanceChains[className]
        if entry and entry.version == inheritanceVersion then
            return entry.chain
        end

        local chain = { [className] = true }
        if not entry then
            entry = { version = inheritanceVersion, chain = chain }
            inheritanceChains[className] = entry
        else
            entry.version = inheritanceVersion
            entry.chain = chain
        end

        local config = _classConfigMap[className]

        if config then
            if config.extendsMap then
                for extendName in pairs(config.extendsMap) do
                    local extendChain = buildInheritanceChain(extendName)
                    for parentName in pairs(extendChain) do
                        chain[parentName] = true
                    end
                end
            end
        end

        return chain
    end

    ---判断一个实例是否属于目标类.
    ---@param obj Object 要判断的实例
    ---@param targetName string|Object 目标类名或目标类对象
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

        local chain = buildInheritanceChain(obj.__class__)
        return chain[targetName] == true
    end

    ---@private
    function ClassMetadata.increaseInheritanceVersion()
        inheritanceVersion = inheritanceVersion + 1
    end
end

-- 刷新指定父类的所有子类继承关系. <br>
-- 只有在完全确定所有子类不会发生变化时才应该调用此函数.
---@param parentClass string|Object 父类名称或父类对象
function ClassControl.refreshInheritance(parentClass)
    local parentName = parentClass.__name or parentClass
    if type(parentName) ~= 'string' then
        _errorHandler('`parentClass` must be a class or class name')
        return
    end

    local parent = _classMap[parentName]
    if not parent then
        _errorHandler(('parent class %q not found'):format(parentName))
        return
    end

    for childName, childConfig in pairs(_classConfigMap) do
        if childConfig.extendsMap and childConfig.extendsMap[parentName] then
            local childClass = _classMap[childName]
            if childClass then
                -- 复制父类的新方法到子类
                copyInheritedMembers(childClass, childConfig, parent, parentName)
            end
        end
    end
end

do
    local superMeta = {
        __call = function(self, ...)
            runInit(self[1], self[2], ...)
            return self[1]
        end
    }

    ---父类构造函数包装器.
    ---@param instance Object 类的实例
    ---@return fun(...: any)
    function ClassControl.super(instance)
        local name = instance.__class__
        if not name then
            _errorHandler('super() 调用失败, 没有找到实例的类名')
        end
        local metadata = getMetadata(name)
        local superClass = metadata and metadata.superClass
        if not superClass then
            _errorHandler(('super() 调用失败, 没有找到父类 %q'):format(name))
        end
        ---@cast superClass -?
        local superName = superClass.__name
        return setmetatable({
            instance,
            superName,
        }, superMeta)
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
---@return Class.Definition
function ClassControl.get(name)
    return _classMap[name]
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

ClassControl.getMetadata = getMetadata
return ClassControl
