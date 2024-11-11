local listener = require "atlas_loader.listener"

local M = {}

local PREFIX = "zip:"

---@type table<hash, atlas_mount_data>
local files = {}
local progress = 0
local files_count = 0
local max_priority = 0

---TODO: change
local PROGRESS_FILE_ERROR = 100
local PROGRESS_COMPLETED = 10000000

local CHECK_PROXY_STATE = hash("CHECK_PROXY_STATE")

local BASE = "_base"

---@enum mount_loader_events
M.EVENTS = {
    LOAD_COMPLETE = hash("LOAD_COMPLETE"),
    DATA_LOADED = hash("DATA_LOADED"),
    DATA_NOT_LOADED = hash("DATA_NOT_LOADED"),
    PROGRESS_CHANGED = hash("PROGRESS_CHANGED")
}

M.events = listener.create()
M.external_key = "external_data" ---Key for saving file in indexDB. Defualt "external_data"
M.use_html_loader = false        ---Allow use of html loader extention to display progress on screen
M.attempt_count = 50             ---Attempts count for loading mount

---@class atlas_mount
---@field name string
---@field priority number
---@field uri string

---@class atlas_mount_info
---@field file_name string
---@field mount_key hash
---@field path_to_file string|nil
---@field priority number|nil
---@field allow_old_mount boolean|nil

---@class atlas_mount_data
---@field file_name string
---@field path_to_file string
---@field priority number
---@field allow_old_mount boolean
---@field mount_key hash
---@field proxies url[]
---@field processing boolean
---@field old_mount_using boolean
---@field loaded boolean

---Check if the data already mounted
---@param data atlas_mount_data
---@param mounts atlas_mount[]
---@return boolean
local function is_in_mount(data, mounts)
    for key, mount in pairs(mounts) do
        if data.file_name == mount.name then
            return true
        end
    end
    return false
end

---Return data
---@param mount_key hash
---@return atlas_mount_data
local function get_data(mount_key)
    local data = files[mount_key]
    if not data then
        ---@type atlas_mount_data
        data = {
            mount_key = mount_key,
            file_name = "",
            path_to_file = "./",
            priority = 0,
            allow_old_mount = false,
            proxies = {},
            processing = false,
            loaded = false,
            old_mount_using = false
        }
        files[mount_key] = data
        files_count = files_count + 1
    end
    return data
end

---Increase progress value
---@param value number
local function add_progress(value)
    progress = progress + value / files_count
    if progress > 100 then
        progress = 100
    end
    if M.use_html_loader and html_loader then
        html_loader.set_progress(progress)
    end
    M.events.trigger(M.EVENTS.PROGRESS_CHANGED, {progress = progress})
end

---Check for complete loading
local function check_for_complete()
    local process_files = false
    for key, data in pairs(files) do
        if data.processing then
            process_files = true
            break
        end
    end
    if not process_files then
        add_progress(PROGRESS_COMPLETED)
        M.events.trigger(M.EVENTS.LOAD_COMPLETE)
        if M.use_html_loader and html_loader then
            html_loader.hide()
        end
    end
end

---Mark mount as loaded
---@param data atlas_mount_data
local function mount_loaded(data)
    data.loaded = true
    data.processing = false
    for key, url in pairs(data.proxies) do
        msg.post(url, CHECK_PROXY_STATE)
    end
    M.events.trigger(M.EVENTS.DATA_LOADED, {mount_key = data.mount_key})
    check_for_complete()
end

---Handle error
---@param data atlas_mount_data
---@param error string
local function on_error(data, error)
    data.loaded = false
    data.processing = false
    if data.allow_old_mount then
        data.old_mount_using = true
        for key, url in pairs(data.proxies) do
            msg.post(url, CHECK_PROXY_STATE)
        end
    else
        add_progress(PROGRESS_FILE_ERROR)
    end
    if M.use_html_loader and html_loader then
        html_loader.set_text("Loading error")
    end
    M.events.trigger(M.EVENTS.DATA_NOT_LOADED, {mount_key = data.mount_key, error = tostring(error)})
    check_for_complete()
end

---Mount data
---@param data atlas_mount_data
---@param save_path string
---@param priority number
local function on_file_received(data, save_path, priority)
    liveupdate.add_mount(data.file_name, PREFIX .. save_path, priority, function(self, name, uri, priority)
        mount_loaded(data)
    end)
end

---Request data
---@param data atlas_mount_data
---@param index number
---@param attempt number|nil
local function request_data(data, index, attempt)
    attempt = attempt or 1
    -- global used here to workaround this issue until it will be fixed in the engine:
    -- https://github.com/defold/defold/pull/8906/files#r1729148892
    ---TODO: add info about loading
    _G.atlas_loader_save_path = sys.get_save_file(M.external_key, data.file_name)
    http.request(data.path_to_file .. data.file_name, "GET", function(self, id, response)
        if (response.status == 200 or response.status == 304) and response.error == nil then
            on_file_received(data, response.path, index)
        elseif response.status >= 400 or response.status == 0 or response.error ~= nil then
            if attempt <= M.attempt_count then
                attempt = attempt + 1
                request_data(data, index, attempt)
            else
                on_error(data, response.error)
            end
        end
    end, {}, nil, {path = _G.atlas_loader_save_path})
end

---Return max priority
---@param mounts atlas_mount[]
local function get_max_priority(mounts)
    for key, mount in pairs(mounts) do
        if mount.priority > max_priority then
            max_priority = mount.priority
        end
    end
    max_priority = max_priority + 1
    return max_priority
end

---Check if the mount loaded
---@param mount_key hash
---@return boolean
function M.is_mount_loaded(mount_key)
    local data = get_data(mount_key)
    return data.loaded
end

---Check if the mount processing
---@param mount_key hash
---@return boolean
function M.is_mount_processing(mount_key)
    local data = get_data(mount_key)
    return data.processing
end

---Check if can be used old mount
---@param mount_key hash
---@return boolean
function M.is_old_mount_available(mount_key)
    local data = get_data(mount_key)
    return data.old_mount_using
end

---Return mount data
---@param mount_key hash
---@return atlas_mount_data|nil
function M.get_mount_data(mount_key)
    return files[mount_key]
end

---Load external data
---@param info atlas_mount_info
function M.load(info)
    local data = get_data(info.mount_key)
    assert(not data.processing, "Mount is in processing. File name: " .. tostring(data.file_name) .. "; Mount key: " .. tostring(data.mount_key))
    assert(not data.loaded, "Mount already loaded. File name: " .. tostring(data.file_name) .. "; Mount key: " .. tostring(data.mount_key))
    data.allow_old_mount = info.allow_old_mount == true
    data.priority = info.priority and info.priority or data.priority
    data.path_to_file = info.path_to_file and info.path_to_file or data.path_to_file
    data.file_name = info.file_name and info.file_name or data.file_name
    data.processing = true
    if M.use_html_loader and html_loader then
        html_loader.show()
    end
    if not liveupdate then
        mount_loaded(data)
    else
        ---@type atlas_mount[]
        local mounts = liveupdate.get_mounts()
        if is_in_mount(data, mounts) then
            mount_loaded(data)
        else
            if not info.priority then
                data.priority = get_max_priority(mounts)
            end
            if data.priority > max_priority then
                max_priority = data.priority
            end
            request_data(data, data.priority)
        end
    end
end

---Check if any old mount is using
---@return boolean
function M.is_old_mount_using()
    for i, data in pairs(files) do
        if data.old_mount_using then
            return true
        end
    end
    return false
end

---Remove not used mounts. Doesn't check if old mounts are in use. Check via `is_old_mount_using`
---@return boolean success
---@return string|nil error
function M.remove_free_mounts()
    if not liveupdate then
        return true
    end
    ---@type atlas_mount[]
    local mounts = liveupdate.get_mounts()
    local old_mount
    for key, mount in pairs(mounts) do
        if mount.name ~= BASE then
            old_mount = true
            for i, data in pairs(files) do
                if mount.name == data.file_name then
                    old_mount = false
                    break
                end
            end
            if old_mount then
                M.remove_mount(mount)
            end
        end
    end
    return true
end

---Remove mount
---@param mount atlas_mount
---@return boolean
---@return string|nil
function M.remove_mount(mount)
    local path = string.sub(mount.uri, #PREFIX + 1)
    local success, err_msg = os.remove(path)
    if success then
        liveupdate.remove_mount(mount.name)
        return true
    else
        ---Error occured
        return false, err_msg
    end
end

---Register proxy
---@param mount_key hash
---@param url url|nil
function M.register_proxy(mount_key, url)
    local data = get_data(mount_key)
    table.insert(data.proxies, url)
end

return M
