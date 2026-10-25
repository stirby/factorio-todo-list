--[[
  Remote interface: lets other mods read and update the todo list. Any mod can, for example, register an assignee
  that isn't a player (an NPC, a team, a bot), take the tasks assigned to it, report progress on them as a status
  line and its own subtasks, and complete them; or just watch the list and react when it changes.

    remote.call("Todo-List", "version")                 -> 1
    remote.call("Todo-List", "get_event_ids")           -> { on_tasks_changed = <event id> }
    remote.call("Todo-List", "get_tasks", include_done) -> array of tasks, open ones in list order (then done ones)
    remote.call("Todo-List", "get_task", id)            -> one task, or nil
        a task: { id, title, task, assignee, created_by, done, status, status_kind,
                  subtasks = { { id, task, done, owner } } }
    remote.call("Todo-List", "add_task", { title, task, assignee, top, created_by }) -> id, or nil
    remote.call("Todo-List", "update_task", id, { title, task, assignee, status, status_kind }) -> bool
        status: a short line shown under the task's title ("" clears it); status_kind colours it:
        "info", "progress", "attention", "error" or "success"; assignee "" unassigns
    remote.call("Todo-List", "set_subtasks", id, owner, { { task, done } }) -> bool
        replaces the subtasks `owner` (any name, e.g. your mod's) made on that task; other subtasks stay
    remote.call("Todo-List", "mark_complete", id) -> bool
    remote.call("Todo-List", "mark_open", id)     -> bool
    remote.call("Todo-List", "add_assignee", name)    -- offered in the assignee drop-downs, after the players
    remote.call("Todo-List", "remove_assignee", name)

  on_tasks_changed is raised after any change to the list, from the UI or from a remote call:
    script.on_event(remote.call("Todo-List", "get_event_ids").on_tasks_changed, function(event) ... end)
  It isn't raised again while its handlers run, so a handler can update tasks; only change what needs changing.

  Every call validates its input (a remote caller can pass anything) and returns false or nil instead of raising.
]]--

todo.STATUS_KINDS = { info = true, progress = true, attention = true, error = true, success = true }

todo.on_tasks_changed = script.generate_event_name()

local raising = false

function todo.raise_tasks_changed()
    if raising then
        return
    end
    raising = true
    local ok, err = pcall(script.raise_event, todo.on_tasks_changed, {})
    raising = false
    if not ok then
        todo.log("An on_tasks_changed handler failed: " .. tostring(err))
    end
end

local function is_text(value)
    return type(value) == "string" and value ~= ""
end

local function external_assignees()
    if not storage.todo.external_assignees then
        storage.todo.external_assignees = {}
    end
    return storage.todo.external_assignees
end

function todo.get_external_assignees()
    return external_assignees()
end

local function copy_subtasks(task)
    local result = {}
    if task.subtasks then
        for _, subtask in ipairs(task.subtasks.open) do
            table.insert(result, { id = subtask.id, task = subtask.task, done = false, owner = subtask.owner })
        end
        for _, subtask in ipairs(task.subtasks.done) do
            table.insert(result, { id = subtask.id, task = subtask.task, done = true, owner = subtask.owner })
        end
    end
    return result
end

local function copy_task(task, done)
    return {
        id = task.id,
        title = task.title,
        task = task.task,
        assignee = task.assignee,
        created_by = task.created_by,
        done = done,
        status = task.status,
        status_kind = task.status_kind,
        subtasks = copy_subtasks(task)
    }
end

local function open_index(id)
    for i, task in ipairs(storage.todo.open) do
        if (task.id == id) then
            return i
        end
    end
end

local function done_index(id)
    for i, task in ipairs(storage.todo.done) do
        if (task.id == id) then
            return i
        end
    end
end

function todo.remote_get_tasks(include_done)
    local result = {}
    for _, task in ipairs(storage.todo.open) do
        table.insert(result, copy_task(task, false))
    end
    if (include_done == true) then
        for _, task in ipairs(storage.todo.done) do
            table.insert(result, copy_task(task, true))
        end
    end
    return result
end

function todo.remote_get_task(id)
    if type(id) ~= "number" then
        return nil
    end
    local i = open_index(id)
    if i then
        return copy_task(storage.todo.open[i], false)
    end
    i = done_index(id)
    if i then
        return copy_task(storage.todo.done[i], true)
    end
    return nil
end

function todo.remote_add_assignee(name)
    if not is_text(name) then
        return false
    end
    local names = external_assignees()
    for _, existing in ipairs(names) do
        if (existing == name) then
            return true
        end
    end
    todo.log("Adding external assignee " .. name)
    table.insert(names, name)
    return true
end

function todo.remote_remove_assignee(name)
    if not is_text(name) then
        return false
    end
    local names = external_assignees()
    for i, existing in ipairs(names) do
        if (existing == name) then
            todo.log("Removing external assignee " .. name)
            table.remove(names, i)
            return true
        end
    end
    return false
end

function todo.remote_add_task(input)
    if type(input) ~= "table" then
        return nil
    end

    local text = type(input.task) == "string" and input.task or ""
    local title = input.title
    if not is_text(title) then
        title = string.match(text, "[^\r\n]+")
    end
    if not is_text(title) then
        return nil
    end

    local task = {}
    task.id = todo.next_task_id()
    task.title = title
    task.task = text
    if is_text(input.assignee) then
        task.assignee = input.assignee
    end
    task.created_by = is_text(input.created_by) and input.created_by or "script"
    task.updated_by = task.created_by

    todo.log("Adding task by remote call: " .. serpent.line(task))
    todo.save_task_to_open_list(task, input.top == true)
    todo.update_main_task_list_for_everyone()

    return task.id
end

function todo.remote_update_task(id, fields)
    if type(id) ~= "number" or type(fields) ~= "table" then
        return false
    end
    local task = todo.get_task_by_id(id)
    if not task then
        return false
    end

    local changed = false
    local function set(key, value)
        if task[key] ~= value then
            task[key] = value
            changed = true
        end
    end

    if is_text(fields.title) then
        set("title", fields.title)
    end
    if type(fields.task) == "string" then
        set("task", fields.task)
    end
    if type(fields.assignee) == "string" then
        -- "" unassigns
        set("assignee", fields.assignee ~= "" and fields.assignee or nil)
    end
    if type(fields.status) == "string" then
        -- "" clears the status line
        set("status", fields.status ~= "" and string.sub(fields.status, 1, 200) or nil)
    end
    if type(fields.status_kind) == "string" then
        set("status_kind", todo.STATUS_KINDS[fields.status_kind] and fields.status_kind or nil)
    end

    if changed then
        todo.update_main_task_list_for_everyone()
    end
    return true
end

function todo.remote_set_subtasks(id, owner, list)
    if type(id) ~= "number" or not is_text(owner) or type(list) ~= "table" then
        return false
    end
    local task = todo.get_task_by_id(id)
    if not task then
        return false
    end

    local wanted = {}
    for _, item in ipairs(list) do
        if type(item) == "table" and is_text(item.task) then
            table.insert(wanted, { task = item.task, done = item.done == true })
        end
    end

    if (not task.subtasks) then
        task.subtasks = { open = {}, done = {}, next_id = 1 }
    end

    -- nothing to do when the owner's subtasks already read the same: no refresh for every player
    local current = {}
    for _, subtask in ipairs(copy_subtasks(task)) do
        if (subtask.owner == owner) then
            table.insert(current, subtask)
        end
    end
    local same = #current == #wanted
    if same then
        -- copy_subtasks lists the open ones before the done ones; compare in that order
        local ordered = {}
        for _, item in ipairs(wanted) do
            if not item.done then table.insert(ordered, item) end
        end
        for _, item in ipairs(wanted) do
            if item.done then table.insert(ordered, item) end
        end
        for i, item in ipairs(ordered) do
            if current[i].task ~= item.task or current[i].done ~= item.done then
                same = false
                break
            end
        end
    end
    if same then
        return true
    end

    for _, list_name in ipairs({ "open", "done" }) do
        local subtasks = task.subtasks[list_name]
        for i = #subtasks, 1, -1 do
            if (subtasks[i].owner == owner) then
                table.remove(subtasks, i)
            end
        end
    end

    for _, item in ipairs(wanted) do
        local subtask = { id = task.subtasks.next_id, task = item.task, owner = owner }
        task.subtasks.next_id = task.subtasks.next_id + 1
        table.insert(item.done and task.subtasks.done or task.subtasks.open, subtask)
    end

    todo.update_main_task_list_for_everyone()
    return true
end

function todo.remote_mark_complete(id)
    if type(id) ~= "number" or not open_index(id) then
        return false
    end
    todo.mark_complete(id)
    todo.update_main_task_list_for_everyone()
    return true
end

function todo.remote_mark_open(id)
    if type(id) ~= "number" or not done_index(id) then
        return false
    end
    todo.task_mark_open(id)
    todo.update_main_task_list_for_everyone()
    return true
end

remote.add_interface("Todo-List", {
    version = function() return 1 end,
    get_event_ids = function() return { on_tasks_changed = todo.on_tasks_changed } end,
    get_tasks = function(include_done) return todo.remote_get_tasks(include_done) end,
    get_task = function(id) return todo.remote_get_task(id) end,
    add_assignee = function(name) return todo.remote_add_assignee(name) end,
    remove_assignee = function(name) return todo.remote_remove_assignee(name) end,
    add_task = function(input) return todo.remote_add_task(input) end,
    update_task = function(id, fields) return todo.remote_update_task(id, fields) end,
    set_subtasks = function(id, owner, list) return todo.remote_set_subtasks(id, owner, list) end,
    mark_complete = function(id) return todo.remote_mark_complete(id) end,
    mark_open = function(id) return todo.remote_mark_open(id) end,
})
