--https://github.com/KristalTeam/Kristal/blob/main/src/utils/gitfinder.lua
local fs       = require 'bee.filesystem'
local util = require 'utility'
-- Contains helper functions to retrieve the current revision of the engine, in the case
-- it was cloned as a Git repo.
local GitFinder = {}

local function is_probing_info_possible(git_path)
    -- If true, the engine is cloned as a git repo, the otherwise if false.
    local is_git_repo = fs.exists(git_path)

    -- Whether probing the info of the repo simply with filesystem operations is possible.
    --
    -- If the engine is a submodule of another repo, this will be false.
    -- In this case, the `.git` file will be plain text containing
    -- `gitdir: path/to/true/git/folder`; it's likely not possible (considering LÖVE's sandbox)
    -- and pointless to follow the semi-symlink.
    return is_git_repo and fs.is_directory(git_path)
end

-- Retrieves the engine's current commit (revision), if it was cloned as a Git repo. \
-- May fail if the engine is not a Git repo, the repo is broken, etc.
---@return string|nil commit The SHA-1 hash for the current commit, or nil in case of failure
return function (project_dir)
    local git_dir = fs.absolute(fs.path(project_dir)):string().."/.git"
    if not is_probing_info_possible(git_dir) then return end
    
    -- Get current HEAD
    local head, _ = util.loadFile(git_dir.."/HEAD", true)
    if not head then return end
    -- Try to get the reference it may point to
    local ref = head:match("^ref: ([^\r\n]*)")
    if ref then -- HEAD is not detached
        -- Read the ref's correspending file, which contains the hash of the commit that it points to
        local commit, _ = util.loadFile(git_dir.."/"..ref, true)
        return commit:gsub("%s+", "")
    else -- HEAD is detached
        -- The file just contains the hash of the commit it's at
        return head:gsub("%s+", "")
    end
end