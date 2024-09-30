local listener = require "atlas_loader.listener"

local M = {}

local PREFIX = "zip:"

---@type table<string, boolean>
local loaded = {}
---@type table<string, boolean>
local old_mount_used = {}
---@type external_data[]
local files = {}
local external_key = "external_data"
local progress = 0
local busy = false

---@type table<hash, url>
local proxies = {}
---@type table<hash, table>
local resources = {}

local PROGRESS_FILE_ERROR = 100
local PROGRESS_FILE_CREATED = 50
local PROGRESS_PROXY_LOADED = 50
local PROGRESS_COMPLETED = 10000000
local ATTEMPT_COUNT = 50

M.LOAD_COMPLETE = hash("LOAD_COMPLETE")
M.DATA_LOADED = hash("DATA_LOADED")
M.DATA_NOT_LOADED = hash("DATA_NOT_LOADED")
M.PROGRESS_CHANGED = hash("PROGRESS_CHANGED")
M.LOAD_PROXY = hash("LOAD_PROXY")

local BASE = "_base"

M.events = listener.create()

M.use_html_loader = false

---@class mount
---@field name string
---@field priority number
---@field uri string

---@class external_data
---@field name string
---@field proxy_name hash
---@field path string|nil
---@field priority number
---@field allow_old_mount boolean

---Check if the data already mounted
---@param data external_data
---@param mounts mount[]
---@return boolean
local function is_in_mount(data, mounts)
    for key, mount in pairs(mounts) do
        if data.name == mount.name then
            return true
        end
    end
    return false
end

---Increase progress value
---@param value number
local function add_progress(value)
    progress = progress + value / #files
    if progress > 100 then
        progress = 100
    end
    if M.use_html_loader and html_loader then
        html_loader.set_progress(progress)
    end
    M.events.trigger(M.PROGRESS_CHANGED, {progress = progress})
end

---Start proxy loading
---@param proxy_name hash
local function load_proxy(proxy_name)
    add_progress(PROGRESS_FILE_CREATED)
    local url = proxies[proxy_name]
    assert(url ~= nil, "No proxy found with the name " .. tostring(proxy_name))
    msg.post(url, M.LOAD_PROXY)
end

---Check for complete loading
local function check_for_complete()
    ---Check old mounts
    local load_started = false
    for i, data in pairs(files) do
        if data.allow_old_mount and loaded[data.name] == false and resources[data.proxy_name] and next(resources[data.proxy_name]) == nil then
            load_started = true
            load_proxy(data.proxy_name)
        end
    end
    if load_started then
        return
    end

    ---Check that all files handled
    local completed = true
    for i, data in pairs(files) do
        if loaded[data.name] == nil then
            completed = false
            break
        end
    end
    if completed then
        busy = false
        add_progress(PROGRESS_COMPLETED)
        M.events.trigger(M.LOAD_COMPLETE)
        if M.use_html_loader and html_loader then
            html_loader.hide()
        end
    end
end

---Handle error
---@param data external_data
---@param error string
local function on_error(data, error)
    loaded[data.name] = false
    M.events.trigger(M.DATA_NOT_LOADED, {mount_name = data.name, proxy_name = data.proxy_name, error = tostring(error)})
    if not data.allow_old_mount then
        add_progress(PROGRESS_FILE_ERROR)
    end
    check_for_complete()
    if M.use_html_loader and html_loader then
        html_loader.set_text("Loading error")
    end
end

---Mount data
---@param data external_data
---@param save_path string
---@param priority number
local function on_file_received(data, save_path, priority)
    liveupdate.add_mount(data.name, PREFIX .. save_path, priority, function(self, name, uri, priority)
        load_proxy(data.proxy_name)
    end)
end

---Request data
---@param data external_data
---@param index number
---@param attempt number|nil
local function request_data(data, index, attempt)
    attempt = attempt or 1
    -- global used here to workaround this issue until it will be fixed in the engine:
    -- https://github.com/defold/defold/pull/8906/files#r1729148892
    _G.atlas_loader_save_path = sys.get_save_file(external_key, data.name)
    http.request(data.path .. data.name, "GET", function(self, id, response)
        if (response.status == 200 or response.status == 304) and response.error == nil then
            on_file_received(data, response.path, index)
        elseif response.status >= 400 or response.status == 0 or response.error ~= nil then
            if attempt <= ATTEMPT_COUNT then
                attempt = attempt + 1
                request_data(data, index, attempt)
            else
                on_error(data, response.error)
            end
        end
    end, {}, nil, {path = _G.atlas_loader_save_path})
end

---Check if the proxy loaded
---@param data external_data
---@return boolean
function M.is_proxy_loaded(data)
    return loaded[data.name] == true
end

---Check if the mount loaded
---@param data external_data
---@return boolean
function M.is_mount_loaded(data)
    return loaded[data.name] == true and not old_mount_used[data.name]
end

---Check if the proxy exist
---@param data external_data
---@return boolean
function M.is_proxy_exist(data)
    return proxies[data.proxy_name] ~= nil
end

---Initialize module
---@param _files external_data[]
---@param _external_key string|nil key for saving file in the index db
function M.init(_files, _external_key)
    if busy then
        return
    end
    files = _files
    external_key = _external_key or external_key
end

---Load external data
function M.load()
    ---TODO: add callback
    ---TODO: add more proxy to one archive
    if busy or #files == 0 then
        return
    end
    busy = true
    progress = 0
    if M.use_html_loader and html_loader then
        html_loader.show()
    end
    if not liveupdate then
        for i, data in pairs(files) do
            assert(M.is_proxy_exist(data), "No proxy found with the name " .. tostring(data.proxy_name))
            load_proxy(data.proxy_name)
        end
    else
        ---@type mount[]
        local mounts = liveupdate.get_mounts()
        for i, data in pairs(files) do
            assert(M.is_proxy_exist(data), "No proxy found with the name " .. tostring(data.proxy_name))
            if not M.is_proxy_loaded(data) then
                if is_in_mount(data, mounts) then
                    load_proxy(data.proxy_name)
                else
                    if not data.path then
                        data.path = "./"
                    end
                    request_data(data, data.priority or i)
                end
            else
                add_progress(PROGRESS_FILE_CREATED)
            end
        end
    end
end

---Remove old mounts
function M.remove_old_mounts()
    if not liveupdate then
        return
    end
    ---@type mount[]
    local mounts = liveupdate.get_mounts()
    local old_mount
    for key, mount in pairs(mounts) do
        if mount.name ~= BASE then
            old_mount = true
            for i, data in pairs(files) do
                if mount.name == data.name then
                    old_mount = false
                    break
                end
            end
            if old_mount then
                local path = string.sub(mount.uri, #PREFIX + 1)
                local success, err_msg = os.remove(path)
                if success then
                    liveupdate.remove_mount(mount.name)
                else
                    error(err_msg)
                end
            end
        end
    end
end

---Called when proxy loaded
---@param name hash
---@param sender url
function M.proxy_loaded(name, sender)
    for key, data in pairs(files) do
        if data.proxy_name == name then
            if loaded[data.name] == false then
                old_mount_used[data.name] = true
            end
            loaded[data.name] = true
            M.events.trigger(M.DATA_LOADED, {name = data.name, proxy_name = data.proxy_name, proxy = sender})
            add_progress(PROGRESS_PROXY_LOADED)
            break
        end
    end
    check_for_complete()
end

---Register proxy
---@param name hash
---@param missing_resources table
---@param url url|nil
function M.register_proxy(name, missing_resources, url)
    proxies[name] = url or msg.url()
    resources[name] = missing_resources
end

return M
