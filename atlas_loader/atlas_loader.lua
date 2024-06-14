local listener = require "atlas_loader.listener"

local M = {}

M.ATLAS_LOADED = hash("ATLAS_LOADED")
M.ATLAS_UNLOADED = hash("ATLAS_UNLOADED")
M.LOAD_ATLAS = hash("LOAD_ATLAS")
M.UNLOAD_ATLAS = hash("UNLOAD_ATLAS")

---@type hash|nil
local current_factory = nil
---@type hash|nil
local previous_factory = nil
---@type table<hash, function>
local callbacks = {}

---@type table<hash, hash|nil>
local loaded_atlases = {}

---@type table<hash, url>
M.factories = {}
M.events = listener.create()
---@type boolean
M.auto_unload = true
---@type boolean
M.enable_log = true

---Print data
---@param data string
local function log(data)
    if M.enable_log then
        print(data)
    end
end

---Handle callback
---@param callback function|nil
---@param param any
local function handle_callback(callback, param)
    if callback then
        callback(param)
    end
end

---Return factory url
---@param name hash
---@return url
local function get_factory_url(name)
    local url = M.factories[name]
    assert(url ~= nil, "No atlas found with the name " .. tostring(name))
    return url
end

---Initialize module
---@param auto_unload boolean|nil
function M.init(auto_unload)
    if auto_unload ~= nil then
        M.auto_unload = auto_unload
    end
end

---Register new factory
---@param name hash
---@param url url|nil
function M.register_factory(name, url)
    M.factories[name] = url or msg.url()
end

---Called when atlas loaded
---@param name hash
---@param atlas hash
function M.atlas_loaded(name, atlas)
    log("Atlas loaded: " .. tostring(name))
    previous_factory = current_factory
    current_factory = name
    loaded_atlases[name] = atlas
    if M.auto_unload and previous_factory and previous_factory ~= current_factory and M.is_atlas_loaded(previous_factory) then
        M.unload(previous_factory)
    end
    M.events.trigger(M.ATLAS_LOADED, {atlas = atlas, name = name})
    handle_callback(callbacks[name], {atlas = atlas, name = name})
end

---Called when atlas unloaded
---@param name hash
function M.atlas_unloaded(name)
    log("Atlas unloaded: " .. tostring(name))
    loaded_atlases[name] = nil
    M.events.trigger(M.ATLAS_UNLOADED, {name = name})
    handle_callback(callbacks[name], {name = name})
end

---Load atlas
---@param name hash
---@param callback function|nil called when atlas loaded
function M.load(name, callback)
    assert(loaded_atlases[name] == nil, "An atlas with this name has already been loaded. " .. tostring(name))
    local url = get_factory_url(name)
    log("Start loading: " .. tostring(name))
    msg.post(url, M.LOAD_ATLAS)
    callbacks[name] = callback
end

---Unload atlas
---@param name hash
---@param callback function|nil called when atlas loaded
function M.unload(name, callback)
    assert(loaded_atlases[name] ~= nil, "The atlas with this name has not been loaded. " .. tostring(name))
    local url = get_factory_url(name)
    log("Start unloading: " .. tostring(name))
    msg.post(url, M.UNLOAD_ATLAS)
    callbacks[name] = callback
end

---Return atlas
---@param name hash
---@return hash|nil
function M.get_atlas(name)
    return loaded_atlases[name]
end

---Check if atlas loaded
---@param name hash
---@return boolean
function M.is_atlas_loaded(name)
    return loaded_atlases[name] ~= nil
end

---Check if factory exist
---@param name hash
---@return boolean
function M.is_factory_exist(name)
    return M.factories[name] ~= nil
end

return M
