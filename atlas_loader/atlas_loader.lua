local listener = require "atlas_loader.listener"
local mount_loader = require "atlas_loader.mount_loader"

local M = {}

---@enum atlas_loader_events
M.EVENTS = {
    ATLAS_LOADED = hash("ATLAS_LOADED"),
    ATLAS_UNLOADED = hash("ATLAS_UNLOADED"),
    PROXY_LOADED = hash("PROXY_LOADED"),
    PROXY_UNLOADED = hash("PROXY_UNLOADED")
}

M.events = listener.create()

local NOT_EXCLUDED = hash("UNKNOWN")
local LOAD_PROXY = hash("LOAD_PROXY")
local UNLOAD_PROXY = hash("UNLOAD_PROXY")
local LOAD_ATLAS = hash("LOAD_ATLAS")
local UNLOAD_ATLAS = hash("UNLOAD_ATLAS")

---@class atlas_proxy_data
---@field url url       Url to script component
---@field proxy_url url Url to proxy component
---@field mount_key hash
---@field name hash
---@field loaded boolean
---@field enough_resources boolean
---@field missing_resources table

---@type hash|nil
local current_factory = nil
---@type hash|nil
local previous_factory = nil
---@type table<hash, function>
local callbacks = {}
---@type table<hash, hash|nil>
local loaded_atlases = {}
---@type table<hash, atlas_proxy_data>
local proxies = {}
---@type table<hash, boolean>
local proxy_wait_list = {}

---@type table<hash, url>
M.factories = {}

---@type boolean
M.auto_unload_atlas = false ---Enable auto unloading for atlases
---@type boolean
M.enable_log = false

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
    assert(url ~= nil, "Factory missing for atlas: " .. tostring(name))
    return url
end

---Load atlas
---@param name hash
---@param callback function|nil called when atlas loaded
function M.load_atlas(name, callback)
    assert(loaded_atlases[name] == nil, "The atlas has already been loaded. Name: " .. tostring(name))
    local url = get_factory_url(name)
    log("Start loading atlas: " .. tostring(name))
    msg.post(url, LOAD_ATLAS)
    callbacks[name] = callback
end

---Unload atlas
---@param name hash
---@param callback function|nil called when atlas loaded
function M.unload_atlas(name, callback)
    assert(loaded_atlases[name] ~= nil, "The atlas was not loaded. Name: " .. tostring(name))
    local url = get_factory_url(name)
    log("Start unloading atlas: " .. tostring(name))
    msg.post(url, UNLOAD_ATLAS)
    callbacks[name] = callback
end

---Return atlas
---@param name hash
---@return hash|nil
function M.get_atlas(name)
    return loaded_atlases[name]
end

---Check if factory exist
---@param name hash
---@return boolean
function M.is_factory_exist(name)
    return M.factories[name] ~= nil
end

---Start proxy loading
---@param name hash
---@param wait_mount boolean|nil if the mount is not loaded, the proxy will be placed on the waiting list
function M.load_proxy(name, wait_mount)
    assert(M.is_proxy_exist(name), "No proxy found with the name: " .. tostring(name))
    local proxy = proxies[name]
    assert(not proxy.loaded, "The proxy has already been loaded. Name: " .. tostring(name))
    if proxy.enough_resources and (mount_loader.is_mount_loaded(proxy.mount_key) or proxy.mount_key == NOT_EXCLUDED or mount_loader.is_old_mount_available(proxy.mount_key)) then
        msg.post(proxy.url, LOAD_PROXY)
        log("Start loading proxy: " .. tostring(name))
    elseif wait_mount then
        proxy_wait_list[name] = true
        log("Proxy on the waiting list: " .. tostring(name))
    else
        error("Mount for proxy not loaded. Proxy name: " .. tostring(proxy.name) .. " Mount key: " .. tostring(proxy.mount_key))
    end
end

---Unload proxy. Remove from waiting list if proxy was there
---@param name hash
function M.unload_proxy(name)
    assert(M.is_proxy_exist(name), "No proxy found with the name " .. tostring(name))
    local proxy = proxies[name]
    if proxy_wait_list[name] then
        proxy_wait_list[name] = nil
        log("Proxy removed from the waiting list: " .. tostring(name))
    elseif proxy.loaded then
        msg.post(proxy.url, UNLOAD_PROXY)
        log("Start unloading proxy: " .. tostring(name))
    else
        error("The proxy was not loaded. Name: " .. tostring(name))
    end
end

---Check if the proxy exist
---@param name hash
---@return boolean
function M.is_proxy_exist(name)
    return proxies[name] ~= nil
end

---Check if the proxy loaded
---@param name hash
---@return boolean
function M.is_proxy_loaded(name)
    return proxies[name] ~= nil and proxies[name].loaded
end

---Check if the proxy on the waiting list
---@param name hash
---@return boolean
function M.is_proxy_on_waiting_list(name)
    return proxy_wait_list[name] ~= nil
end

---Return proxy info
---@param name hash
---@return atlas_proxy_data
function M.get_proxy_info(name)
    assert(M.is_proxy_exist(name), "No proxy found with the name " .. tostring(name))
    return proxies[name]
end

---Special functions

---Register new factory
---@param name hash
---@param url url|nil
function M.register_factory(name, url)
    M.factories[name] = url or msg.url()
end

---Unregister unloaded factory
---@param name hash
function M.unregister_factory(name)
    M.factories[name] = nil
end

---Called when atlas loaded
---@param name hash
---@param atlas hash
function M.atlas_loaded(name, atlas)
    log("Atlas loaded: " .. tostring(name))
    previous_factory = current_factory
    current_factory = name
    loaded_atlases[name] = atlas
    if M.auto_unload_atlas and previous_factory and previous_factory ~= current_factory and M.is_atlas_loaded(previous_factory) then
        M.unload_atlas(previous_factory)
    end
    M.events.trigger(M.EVENTS.ATLAS_LOADED, {atlas = atlas, name = name})
    handle_callback(callbacks[name], {atlas = atlas, name = name})
end

---Called when atlas unloaded
---@param name hash
function M.atlas_unloaded(name)
    log("Atlas unloaded: " .. tostring(name))
    loaded_atlases[name] = nil
    M.events.trigger(M.EVENTS.ATLAS_UNLOADED, {name = name})
    handle_callback(callbacks[name], {name = name})
end

---Check if atlas loaded
---@param name hash
---@return boolean
function M.is_atlas_loaded(name)
    return loaded_atlases[name] ~= nil
end

---Called when proxy loaded
---@param name hash
---@param sender url
function M.proxy_loaded(name, sender)
    assert(M.is_proxy_exist(name), "No proxy found with the name " .. tostring(name))
    local proxy = proxies[name]
    proxy_wait_list[proxy.name] = nil
    proxy.loaded = true
    M.events.trigger(M.EVENTS.PROXY_LOADED, {proxy_name = name, proxy_url = sender})
end

---Called when proxy unloaded
---@param name hash
---@param sender url
function M.proxy_unloaded(name, sender)
    assert(M.is_proxy_exist(name), "No proxy found with the name " .. tostring(name))
    local proxy = proxies[name]
    proxy.loaded = false
    M.events.trigger(M.EVENTS.PROXY_UNLOADED, {proxy_name = name, proxy_url = sender})
end

---Check mount loaded state
---@param name hash
---@param missing_resources table
function M.check_proxy_state(name, missing_resources)
    assert(M.is_proxy_exist(name), "No proxy found with the name " .. tostring(name))
    local proxy = proxies[name]
    proxy.missing_resources = missing_resources
    proxy.enough_resources = next(missing_resources) == nil
    if proxy.enough_resources and proxy_wait_list[proxy.name] then
        M.load_proxy(proxy.name)
    end
end

---Register proxy
---@param name hash
---@param mount_key hash
---@param missing_resources table
---@param proxy_url url
---@param url url|nil
function M.register_proxy(name, mount_key, missing_resources, proxy_url, url)
    assert(not M.is_proxy_exist(name), "Proxy already exists with the same name " .. tostring(name))
    proxies[name] = {
        url = url or msg.url(),
        missing_resources = missing_resources,
        name = name,
        mount_key = mount_key,
        proxy_url = proxy_url,
        enough_resources = next(missing_resources) == nil,
        loaded = false
    }
    mount_loader.register_proxy(mount_key, proxies[name].url)
end

return M
