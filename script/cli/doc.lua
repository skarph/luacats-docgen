local lclient  = require 'lclient'
local furi     = require 'file-uri'
local ws       = require 'workspace'
local files    = require 'files'
local util     = require 'utility'
local jsonb    = require 'json-beautify'
local lang     = require 'language'
local define   = require 'proto.define'
local config   = require 'config.config'
local await    = require 'await'
local vm       = require 'vm'
local guide    = require 'parser.guide'
local getDesc  = require 'core.hover.description'
local getLabel = require 'core.hover.label'
local doc2md   = require 'cli.doc2md'
local progress = require 'progress'
local fs       = require 'bee.filesystem'
local getCommit= require 'gitfinder'

local export = {}

--[[
local function newDocEntry(set, source)

    -- class/type --
    local result = {
        name    = global.name,
        type    = 'type',
        desc    = nil,
        rawdesc = nil,
        defines = {},
        fields  = {},
    }

    --for each place where this class is defined:
    result.defines[#result.defines+1] = {
        type    = set.type,
        file    = guide.getUri(set),
        start   = set.start,
        finish  = set.finish,
        extends = getExtends(set),
    }
    result.desc = result.desc or getDesc(set) --gets reset every new time its found?
    result.rawdesc = result.rawdesc or getDesc(set, true) --gets reset every new time its found?

    --for each field (nonfunction) in class:
    local field = {}
    result.fields[#result.fields+1] = field
    if source.field.type == 'doc.field.name' then
        field.name = source.field[1]
    else
        field.name = ('[%s]'):format(vm.getInfer(source.field):view(ws.rootUri))
    end
    field.type    = source.type
    field.file    = guide.getUri(source)
    field.start   = source.start
    field.finish  = source.finish
    field.desc    = getDesc(source)
    field.rawdesc = getDesc(source, true)
    field.extends = packObject(source.extends)
    field.visible = vm.getVisibleType(source)

    --for each method (function) in class:
    local field = {}
    result.fields[#result.fields+1] = field
    field.name    = (source.field or source.method)[1]
    field.type    = source.type
    field.file    = guide.getUri(source)
    field.start   = source.start
    field.finish  = source.finish
    field.desc    = getDesc(source)
    field.rawdesc = getDesc(source, true)
    field.extends = packObject(source.value)
    field.visible = vm.getVisibleType(source)
    if vm.isAsync(source, true) then
        field.async = true
    end
    local depr = vm.getDeprecated(source)
    if (depr and not depr.versions) then
        field.deprecated = true
    end

    --for each table index (unused???) in class:
    local field = {}
    result.fields[#result.fields+1] = field
    field.name    = source.index[1]
    field.type    = source.type
    field.file    = guide.getUri(source)
    field.start   = source.start
    field.finish  = source.finish
    field.desc    = getDesc(source)
    field.rawdesc = getDesc(source, true)
    field.extends = packObject(source.value)
    field.visible = vm.getVisibleType(source)



    -- variable collectVars(global, results) --
    local result = {
        name    = global:getCodeName(),
        type    = 'variable',
        desc    = nil,
        defines = {},
    }

    --for each place where this variable is defined:
    result.defines[#result.defines+1] = {
        type    = set.type,
        file    = guide.getUri(set),
        start   = set.start,
        finish  = set.finish,
        extends = packObject(set.value),
    }
    result.desc = result.desc or getDesc(set)
    result.rawdesc = result.rawdesc or getDesc(set, true)
    result.defines[#result.defines].extends['desc'] = getDesc(set)
    result.defines[#result.defines].extends['rawdesc'] = getDesc(set, true)
    if vm.isAsync(set, true) then
        result.defines[#result.defines].extends['async'] = true
    end
    local depr = vm.getDeprecated(set)
    if (depr and not depr.versions) then
        result.defines[#result.defines].extends['deprecated'] = true
    end
end
]]


---@async
local function packObject(source, mark)
    if type(source) ~= 'table' then
        return source
    end
    if not mark then
        mark = {}
    end
    if mark[source] then
        return
    end
    mark[source] = true
    local new = {}
    if (#source > 0 and next(source, #source) == nil)
    or source.type == 'funcargs' then
        new = {}
        for i = 1, #source do
            new[i] = packObject(source[i], mark)
        end
    else
        for k, v in pairs(source) do
            if k == 'type'
            or k == 'name'
            or k == 'start'
            or k == 'finish'
            or k == 'types' then
                new[k] = packObject(v, mark)
            end
        end
        if source.type == 'function' then
            new['args'] = packObject(source.args, mark)
            local _, _, max = vm.countReturnsOfFunction(source)
            if max > 0 then
                new.returns = {}
                for i = 1, max do
                    local rtn = vm.getReturnOfFunction(source, i)
                    new.returns[i] = packObject(rtn)
                end
            end
            new['view'] = getLabel(source, source.parent.type == 'setmethod')
        end
        if source.type == 'local'
        or source.type == 'self' then
            new['name'] = source[1]
        end
        if source.type == 'function.return' then
            new['desc'] = source.comment and getDesc(source.comment)
            new['rawdesc'] = source.comment and getDesc(source.comment, true)
        end
        if source.type == 'doc.type.table' then
            new['fields'] = packObject(source.fields, mark)
        end
        if source.type == 'doc.field.name'
        or source.type == 'doc.type.arg.name' then
            new['[1]'] = packObject(source[1], mark)
            new['view'] = source[1]
        end
        if source.type == 'doc.type.function' then
            new['args'] = packObject(source.args, mark)
            if source.returns then
                new['returns'] = packObject(source.returns, mark)
            end
        end
        if source.bindDocs then
            new['desc'] = getDesc(source)
            new['rawdesc'] = getDesc(source, true)
        end
        new['view'] = new['view'] or vm.getInfer(source):view(ws.rootUri)
    end
    return new
end

---@async
local function getExtends(source)
    if source.type == 'doc.class' then
        if not source.extends then
            return nil
        end
        return packObject(source.extends)
    end
    if source.type == 'doc.alias' then
        if not source.extends then
            return nil
        end
        return packObject(source.extends)
    end
end

---@class doc
---@field type string
---@field desc string ?
---@field rawdesc string ?

--- makes a new class export table.
---@param global_context vm.global
---@return doc.class
local function createType(global_context)
    ---@class doc.class : doc
    ---@field name string
    ---@field fields doc.field[]
    ---@field defines doc.definition[]
    return {
        name = global_context.name,
        type = 'type',
        desc = nil,
        rawdesc = nil,
        defines = {},
        fields = {},
    }
end

--- makes a new variable export table.
---@param global_context vm.global
---@return doc.variable
local function createVariable(global_context)
    ---@class doc.variable : doc
    ---@field name string
    ---@field defines doc.definition[]
    return { 
        name    = global_context:getCodeName(),
        type    = 'variable',
        desc    = nil,
        rawdesc = nil,
        defines = {},
    }
end

--- makes a new definition table.
---@param set parser.object
---@return doc.definition
local function createDefinition(set)
    ---@class doc.definition : doc
    ---@field file string
    ---@field start integer
    ---@field finish integer
    ---@field extends table ?
    ---@field async boolean
    ---@field deprecated boolean
    return {
        type = set.type,
        file = guide.getUri(set),
        start = set.start,
        finish = set.finish,
        extends = getExtends(set),
        desc = getDesc(set), -- result.desc = result.desc or getDesc(set)
        rawdesc = getDesc(set, true), -- result.rawdesc = result.rawdesc or getDesc(set, true)
        --result.defines[#result.defines].extends['desc'] = getDesc(set)
        --result.defines[#result.defines].extends['rawdesc'] = getDesc(set, true)
        async = vm.isAsync(set, true) and true or false, --if vm.isAsync(set, true) then result.defines[#result.defines].extends['async'] = true end
        deprecated = vm.getDeprecated(set) and true or false, --  if (depr and not depr.versions) the result.defines[#result.defines].extends['deprecated'] = true end
    }
end

--- makes a new field table
---@param source parser.object
---@return doc.field
local function createField(source)
    ---@class doc.field : doc
    ---@field name string
    ---@field file string
    ---@field start integer
    ---@field finish integer
    ---@field extends table ?
    ---@field async boolean
    ---@field deprecated boolean

    local name
    ---@todo: sort this out, make it nice, maybe? it works as is...
    if source.type == 'doc.field' then --field? index
        if source.field.type == 'doc.field.name' then
            name = source.field[1]
        else
            name = ('[%s]'):format(vm.getInfer(source.field):view(ws.rootUri))
        end

    elseif source.type == 'setfield'
        or source.type == 'setmethod' then --method? index
        name = (source.field or source.method)[1]

    elseif source.type == 'tableindex' then --table index
        name = source.index[1]
    end

    return { ---@class doc.field
        name = name,
        type = source.type,
        file = guide.getUri(source),
        start = source.start,
        finish = source.finish,
        desc = getDesc(source), --these stay here since only one def?
        rawdesc = getDesc(source, true), --these stay here since only one def?
        extends = packObject(source.value),
        visible = vm.getVisibleType(source),
        async = vm.isAsync(source, true) and true or false, --if vm.isAsync(source, true) then field.async = true end
        deprecated = (depr and not depr.versions) and true or false --if (depr and not depr.versions) then field.deprecated = true end
    }
end

--true if in blacklist, removes leading full file path 
local blacklist = {".vscode/", "Kristal/mods/", "Kristal/main.lua", METAPATH}
--fix blacklist escape patterns https://github.com/lua-nucleo/lua-nucleo/blob/v0.1.0/lua-nucleo/string.lua#L245-L267
for i, black in ipairs(blacklist) do
    blacklist[i] = black:gsub(".", {
        ["^"] = "%^";
        ["$"] = "%$";
        ["("] = "%(";
        [")"] = "%)";
        ["%"] = "%%";
        ["."] = "%.";
        ["["] = "%[";
        ["]"] = "%]";
        ["*"] = "%*";
        ["+"] = "%+";
        ["-"] = "%-";
        ["?"] = "%?";
        ["\0"] = "%z";
    })
end

---@param path string
local function checkAndFixPath(path)
    for _, black in ipairs(blacklist) do
        --print(_)
        if(path:find(black)) then
            --print("x "..black)
            return false
        end
    end
    return path:find(DOC) and path
end
--------------------------------------------------------

---@async
---@param global vm.global
---@param results table
local function collectTypes(global, results)
    if guide.isBasicType(global.name) then
        return
    end
    local result = createType(global)
    for _, set in ipairs(global:getSets(ws.rootUri)) do
        local uri = guide.getUri(set)
        if files.isLibrary(uri) then
            goto CONTINUE
        end
        if not checkAndFixPath(guide.getUri(set)) then
            goto CONTINUE
        end
        result.defines[#result.defines+1] = createDefinition(set)
        ::CONTINUE::
    end
    if #result.defines == 0 then
        return
    end
    table.sort(result.defines, function (a, b)
        if a.file ~= b.file then
            return a.file < b.file
        end
        return a.start < b.start
    end)
    results[#results+1] = result
    ---@async
    ---@diagnostic disable-next-line: not-yieldable
    vm.getSimpleClassFields(ws.rootUri, global, vm.ANY, function (source, mark, discardParentFields)
        if(discardParentFields) then return end
        --assume this is a class and put it on the inheritance stack 
        if source.type == 'doc.field' then
            ---@cast source parser.object
            if files.isLibrary(guide.getUri(source)) then
                return
            end
            if not checkAndFixPath(guide.getUri(source)) then
                return
            end

            result.fields[#result.fields+1] = createField(source)
        end
        if source.type == 'setfield'
        or source.type == 'setmethod' then
            ---@cast source parser.object
            if files.isLibrary(guide.getUri(source)) then
                return
            end
            if not checkAndFixPath(guide.getUri(source)) then
                return
            end

            result.fields[#result.fields+1] = createField(source)
            return
        end
        if source.type == 'tableindex' then
            ---@cast source parser.object
            if source.index.type ~= 'string' then
                return
            end
            if files.isLibrary(guide.getUri(source)) then
                return
            end

            if not checkAndFixPath(guide.getUri(source)) then
                return
            end

            result.fields[#result.fields+1] = createField(source)
            return
        end
    end)
    table.sort(result.fields, function (a, b)
        if a.name ~= b.name then
            return a.name < b.name
        end
        if a.file ~= b.file then
            return a.file < b.file
        end
        return a.start < b.start
    end)
end

---@async
---@param global vm.global
---@param results table
local function collectVars(global, results)
    local result = createVariable(global)
    for _, set in ipairs(global:getSets(ws.rootUri)) do
        local uri = checkAndFixPath(guide.getUri(set))
        if (set.type == 'setglobal'
        or set.type == 'setfield'
        or set.type == 'setmethod'
        or set.type == 'setindex')
        and uri then
            result.defines[#result.defines+1] = createDefinition(set)

        end
    end
    if #result.defines == 0 then
        return
    end
    table.sort(result.defines, function (a, b)
        if a.file ~= b.file then
            return a.file < b.file
        end
        return a.start < b.start
    end)
    results[#results+1] = result
end

---Add config settings to JSON output.
---@param results table
local function makeMetadata(results, globals_count)
    return {META = {
        blaclist = blacklist,
        commit = getCommit(fs.absolute(fs.path(DOC)):string()),
        count = #results,
        format = 'LuaLS | skarphtest',
        root = fs.absolute(fs.path(DOC)):string(),
        time = os.time(os.date("!*t")),
    }}
end

---@async
---@param callback fun(i, max)
function export.export(outputPath, callback)
    local results = {}
    local globals = vm.getAllGlobals()

    local max = 0
    for _ in pairs(globals) do
        max = max + 1
    end
    local i = 0
    for _, global in pairs(globals) do
        if global.cate == 'variable' then
            collectVars(global, results)
        elseif global.cate == 'type' then
            collectTypes(global, results)
        end
        i = i + 1
        callback(i, max)
    end

    table.sort(results, function (a, b)
        return a.name < b.name
    end)

    table.insert(results, 1, makeMetadata(results, max))
    local docPath = outputPath .. '/doc.json'
    jsonb.supportSparseArray = true
    util.saveFile(docPath, jsonb.beautify(results))

    --local mdPath = doc2md.buildMD(outputPath)
    return docPath, "no markdown"
end

function export.getDocOutputPath()
    local doc_output_path = ''
    if type(DOC_OUT_PATH) == 'string' then
        doc_output_path = fs.absolute(fs.path(DOC_OUT_PATH)):string()
    elseif DOC_OUT_PATH == true then
        doc_output_path = fs.current_path():string()
    else
        doc_output_path = LOGPATH
    end
    return doc_output_path
end

---@async
---@param outputPath string
function export.makeDoc(outputPath)
    ws.awaitReady(ws.rootUri)

    local expandAlias = config.get(ws.rootUri, 'Lua.hover.expandAlias')
    config.set(ws.rootUri, 'Lua.hover.expandAlias', false)
    local _ <close> = function ()
        config.set(ws.rootUri, 'Lua.hover.expandAlias', expandAlias)
    end

    await.sleep(0.1)

    local prog <close> = progress.create(ws.rootUri, '正在生成文档...', 0)
    local docPath, mdPath = export.export(outputPath, function (i, max)
        prog:setMessage(('%d/%d'):format(i, max))
        prog:setPercentage((i) / max * 100)
    end)

    return docPath, mdPath
end


---Find file 'doc.json'.
---@return fs.path
local function findDocJson()
    local doc_json_path
    if type(DOC_UPDATE) == 'string' then
        doc_json_path = fs.absolute(fs.path(DOC_UPDATE)) .. '/doc.json'
    else
        doc_json_path = fs.current_path() .. '/doc.json'
    end
    if fs.exists(doc_json_path) then
        return doc_json_path
    else
        error(string.format('Error: File "%s" not found.', doc_json_path))
    end
end

---@return string # path of 'doc.json'
---@return string # path to be documented
local function getPathDocUpdate()
    local doc_json_path = findDocJson()
    local ok, doc_path = pcall(
        function ()
            local json = require('json')
            local json_file = io.open(doc_json_path:string(), 'r'):read('*all')
            local json_data = json.decode(json_file)
            for _, section in ipairs(json_data) do
                if section.type == 'luals.config' then
                    return section.DOC
                end
            end
    end)
    if ok then
        local doc_json_dir = doc_json_path:string():gsub('/doc.json', '')
        return doc_json_dir, doc_path
    else
        error(string.format('Error: Cannot update "%s".', doc_json_path .. '/doc.json'))
    end
end

function export.runCLI()
    lang(LOCALE)

    if DOC_UPDATE then
        DOC_OUT_PATH, DOC = getPathDocUpdate()
    end

    if type(DOC) ~= 'string' then
        print(lang.script('CLI_CHECK_ERROR_TYPE', type(DOC)))
        return
    end

    local rootUri = furi.encode(fs.absolute(fs.path(DOC)):string())
    if not rootUri then
        print(lang.script('CLI_CHECK_ERROR_URI', DOC))
        return
    end

    print('root uri = ' .. rootUri)

    util.enableCloseFunction()

    local lastClock = os.clock()

    ---@async
    lclient():start(function (client)
        client:registerFakers()

        client:initialize {
            rootUri = rootUri,
        }

        io.write(lang.script('CLI_DOC_INITING'))

        config.set(nil, 'Lua.diagnostics.enable', false)
        config.set(nil, 'Lua.hover.expandAlias', false)

        ws.awaitReady(rootUri)
        await.sleep(0.1)

        local docPath, mdPath = export.export(export.getDocOutputPath(), function (i, max)
            if os.clock() - lastClock > 0.2 then
                lastClock = os.clock()
                local output = '\x0D'
                            .. ('>'):rep(math.ceil(i / max * 20))
                            .. ('='):rep(20 - math.ceil(i / max * 20))
                            .. ' '
                            .. ('0'):rep(#tostring(max) - #tostring(i))
                            .. tostring(i) .. '/' .. tostring(max)
                io.write(output)
            end
        end)

        io.write('\x0D')

        print(lang.script('CLI_DOC_DONE'
            , ('[%s](%s)'):format(files.normalize(docPath), furi.encode(docPath))
            , ('[x]'):format(files.normalize(mdPath),  furi.encode(mdPath))
        ))
    end)
end

return export
