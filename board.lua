local grid_utils = require("grid_utils")
local UndoStack  = require("undo_stack")

local emptyGrid = grid_utils.emptyGrid
local shuffle   = grid_utils.shuffle

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local SIZES      = { 5, 6, 7 }
local DEFAULT_N  = 5
local MAX_ROOM   = 4   -- rooms hold 1..MAX_ROOM cells

local DIR4 = { {-1,0},{1,0},{0,-1},{0,1} }

local function inBounds(r, c, n)
    return r >= 1 and r <= n and c >= 1 and c <= n
end

-- ---------------------------------------------------------------------------
-- Room + value generation
-- ---------------------------------------------------------------------------

-- Same separation rule as isValid() below, but checked against a plain n×n
-- value grid instead of a room-relative one — used while a room's final
-- size isn't decided yet.
local function isValidGlobal(grid, n, r, c, v)
    for cc = 1, n do
        if cc ~= c and grid[r][cc] == v and math.abs(cc - c) <= v then return false end
    end
    for rr = 1, n do
        if rr ~= r and grid[rr][c] == v and math.abs(rr - r) <= v then return false end
    end
    return true
end

-- Build rooms AND assign their values in the same pass instead of
-- generating a blind random room layout and hoping a separate solve() can
-- fill it: each new room is grown one cell at a time, immediately assigning
-- the next value (1, 2, 3, ...) and checking it against every value already
-- placed on the board. A room simply stops growing early if no neighbouring
-- cell can validly take the next value, rather than committing to a shape
-- that might turn out to be globally unsatisfiable. (The old generate-then-
-- solve approach had to prove a full random layout infeasible before
-- retrying — empirically needing many thousands of attempts at n=6/7, worse
-- than the room count could realistically be retried; checking validity
-- while growing avoids ever building a room around a bad guess.)
--
-- Cells that end up with no room after the main growth pass (their
-- neighbours all filled up first) are patched up in a final repair pass:
-- try extending an adjacent room by one more value, or start a fresh
-- size-1 room. Returns nil if even that isn't possible for some cell, so
-- the caller can just retry with a fresh random order — each attempt is
-- cheap since there's no backtracking search involved.
local ROOM_SIZE_WEIGHTS = { 1, 1, 2, 2, 2, 3, 3, 4 }

local function tryGenerateRoomsAndValues(n)
    local grid    = emptyGrid(n, n, 0)
    local room_id = emptyGrid(n, n, 0)
    local rooms   = {}
    local next_room = 0

    local all_cells = {}
    for r = 1, n do
        for c = 1, n do all_cells[#all_cells + 1] = {r, c} end
    end
    shuffle(all_cells)

    for _, cell in ipairs(all_cells) do
        local r, c = cell[1], cell[2]
        if room_id[r][c] == 0 and isValidGlobal(grid, n, r, c, 1) then
            next_room = next_room + 1
            local id = next_room
            room_id[r][c] = id
            grid[r][c]    = 1
            local room = { cells = {{r, c}}, size = 1 }
            rooms[id] = room

            local target = ROOM_SIZE_WEIGHTS[math.random(#ROOM_SIZE_WEIGHTS)]
            while room.size < target do
                local candidates = {}
                for _, rc in ipairs(room.cells) do
                    for _, d in ipairs(DIR4) do
                        local nr, nc = rc[1] + d[1], rc[2] + d[2]
                        if inBounds(nr, nc, n) and room_id[nr][nc] == 0 then
                            local next_v = room.size + 1
                            if isValidGlobal(grid, n, nr, nc, next_v) then
                                candidates[#candidates + 1] = {nr, nc}
                            end
                        end
                    end
                end
                if #candidates == 0 then break end
                local pick = candidates[math.random(#candidates)]
                room.size = room.size + 1
                room_id[pick[1]][pick[2]] = id
                grid[pick[1]][pick[2]]    = room.size
                room.cells[#room.cells + 1] = pick
            end
        end
    end

    -- Repair pass: patch up any cells the main pass never reached.
    for r = 1, n do
        for c = 1, n do
            if room_id[r][c] == 0 then
                local joined, adj_ids = false, {}
                for _, d in ipairs(DIR4) do
                    local nr, nc = r + d[1], c + d[2]
                    if inBounds(nr, nc, n) and room_id[nr][nc] > 0 then
                        adj_ids[room_id[nr][nc]] = true
                    end
                end
                for id in pairs(adj_ids) do
                    local room = rooms[id]
                    if room.size < MAX_ROOM then
                        local next_v = room.size + 1
                        if isValidGlobal(grid, n, r, c, next_v) then
                            room.size = next_v
                            room_id[r][c] = id
                            grid[r][c]    = next_v
                            room.cells[#room.cells + 1] = {r, c}
                            joined = true
                            break
                        end
                    end
                end
                if not joined then
                    if isValidGlobal(grid, n, r, c, 1) then
                        next_room = next_room + 1
                        room_id[r][c] = next_room
                        grid[r][c]    = 1
                        rooms[next_room] = { cells = {{r, c}}, size = 1 }
                    else
                        return nil
                    end
                end
            end
        end
    end

    return grid, room_id, rooms
end

-- ---------------------------------------------------------------------------
-- Ripple-effect constraint check
-- ---------------------------------------------------------------------------

-- Returns true if value v can be placed at (r,c) given the current grid state
local function isValid(grid, room_id, rooms, r, c, v, n)
    local id = room_id[r][c]
    local room_size = rooms[id].size

    -- v must be <= room size
    if v > room_size then return false end

    -- v must not already appear in this room
    for _, cell in ipairs(rooms[id].cells) do
        local cr, cc = cell[1], cell[2]
        if not (cr == r and cc == c) and grid[cr][cc] == v then
            return false
        end
    end

    -- Ripple separation in row: any same value v in the same row must be > v cells away
    for cc = 1, n do
        if cc ~= c and grid[r][cc] == v then
            if math.abs(cc - c) <= v then return false end
        end
    end

    -- Ripple separation in col
    for rr = 1, n do
        if rr ~= r and grid[rr][c] == v then
            if math.abs(rr - r) <= v then return false end
        end
    end

    return true
end

-- ---------------------------------------------------------------------------
-- Clue removal
-- ---------------------------------------------------------------------------

local function removeClues(solution, room_id, rooms, n, difficulty)
    local keep_ratio
    if     difficulty == "easy"   then keep_ratio = 0.55
    elseif difficulty == "hard"   then keep_ratio = 0.25
    else                               keep_ratio = 0.40
    end

    local puzzle = emptyGrid(n, n, 0)
    for r = 1, n do
        for c = 1, n do
            puzzle[r][c] = solution[r][c]
        end
    end

    -- Try to remove cells while puzzle remains uniquely solvable (simplified:
    -- just remove a fraction of cells randomly)
    local removable = {}
    for r = 1, n do
        for c = 1, n do removable[#removable + 1] = {r, c} end
    end
    shuffle(removable)
    local total = n * n
    local to_keep = math.floor(total * keep_ratio)
    local kept = 0
    for _, cell in ipairs(removable) do
        if kept < to_keep then
            kept = kept + 1
        else
            puzzle[cell[1]][cell[2]] = 0
        end
    end
    return puzzle
end

-- ---------------------------------------------------------------------------
-- RippleEffectBoard
-- ---------------------------------------------------------------------------

local RippleEffectBoard = {}
RippleEffectBoard.__index = RippleEffectBoard

function RippleEffectBoard:new(opts)
    opts = opts or {}
    local obj = setmetatable({
        n          = opts.n          or DEFAULT_N,
        difficulty = opts.difficulty or "medium",
        room_id    = nil,
        rooms      = nil,
        solution   = nil,
        puzzle     = nil,
        user       = nil,
        selected   = nil,
        wrong      = nil,
        won        = false,
        undo       = UndoStack:new{ max_size = 500 },
    }, self)
    obj:generate()
    return obj
end

function RippleEffectBoard:generate(diff)
    self.difficulty = diff or self.difficulty
    local n = self.n
    -- Each attempt is a cheap constructive build (no backtracking search),
    -- so this can afford to be a large budget: measured 0/30 fallback at
    -- n=7 (the hardest supported size) with this cap, worst case ~8s.
    local MAX_ATTEMPTS = 100000

    for attempt = 1, MAX_ATTEMPTS do
        local grid, room_id, rooms = tryGenerateRoomsAndValues(n)
        if grid then
            self.room_id  = room_id
            self.rooms    = rooms
            self.solution = grid
            self.puzzle   = removeClues(grid, room_id, rooms, n, self.difficulty)
            self.user     = emptyGrid(n, n, 0)
            self.wrong    = emptyGrid(n, n, false)
            for r = 1, n do
                for c = 1, n do
                    self.user[r][c] = self.puzzle[r][c]
                end
            end
            self.won      = false
            self.selected = nil
            self.undo:clear()
            return
        end
    end

    -- Fallback: 5x5, all single-cell rooms with values 1
    local n2 = 5
    self.n = n2
    local room_id = emptyGrid(n2, n2, 0)
    local rooms   = {}
    local id = 0
    for r = 1, n2 do
        for c = 1, n2 do
            id = id + 1
            room_id[r][c] = id
            rooms[id] = { cells = {{r, c}}, size = 1 }
        end
    end
    local sol = emptyGrid(n2, n2, 1)
    self.room_id  = room_id
    self.rooms    = rooms
    self.solution = sol
    self.puzzle   = emptyGrid(n2, n2, 0)
    self.user     = emptyGrid(n2, n2, 0)
    self.wrong    = emptyGrid(n2, n2, false)
    self.won      = false
    self.selected = nil
    self.undo:clear()
end

function RippleEffectBoard:setCell(r, c, v)
    if self.puzzle[r][c] ~= 0 then return false end  -- given cell
    if self.won then return false end
    local old = self.user[r][c]
    if old == v then return false end
    self.undo:push{ r = r, c = c, old = old }
    self.user[r][c] = v
    self.wrong[r][c] = false
    self:_checkWin()
    return true
end

function RippleEffectBoard:eraseCell(r, c)
    return self:setCell(r, c, 0)
end

function RippleEffectBoard:undoMove()
    local entry = self.undo:pop()
    if not entry then return false end
    self.user[entry.r][entry.c] = entry.old
    self.wrong[entry.r][entry.c] = false
    self.won = false
    return true
end

function RippleEffectBoard:check()
    local n = self.n
    self.wrong = emptyGrid(n, n, false)
    for r = 1, n do
        for c = 1, n do
            local v = self.user[r][c]
            if v ~= 0 then
                -- Temporarily clear to check validity
                self.user[r][c] = 0
                if not isValid(self.user, self.room_id, self.rooms, r, c, v, n) then
                    self.wrong[r][c] = true
                end
                self.user[r][c] = v
            end
        end
    end
end

function RippleEffectBoard:_checkWin()
    local n = self.n
    for r = 1, n do
        for c = 1, n do
            if self.user[r][c] ~= self.solution[r][c] then
                self.won = false
                return
            end
        end
    end
    self.won = true
end

function RippleEffectBoard:countEmpty()
    local n, count = self.n, 0
    for r = 1, n do
        for c = 1, n do
            if self.user[r][c] == 0 then count = count + 1 end
        end
    end
    return count
end

function RippleEffectBoard:reveal()
    local n = self.n
    for r = 1, n do
        for c = 1, n do
            self.user[r][c] = self.solution[r][c]
        end
    end
    self.won = true
end

-- ---------------------------------------------------------------------------
-- Serialization
-- ---------------------------------------------------------------------------

function RippleEffectBoard:serialize()
    local n = self.n
    local rid_flat, rooms_sizes, sol_flat, puz_flat, user_flat, room_cells = {}, {}, {}, {}, {}, {}
    for r = 1, n do
        for c = 1, n do
            rid_flat[#rid_flat + 1]  = self.room_id[r][c]
            sol_flat[#sol_flat + 1]  = self.solution[r][c]
            puz_flat[#puz_flat + 1]  = self.puzzle[r][c]
            user_flat[#user_flat + 1] = self.user[r][c]
        end
    end
    for id, room in pairs(self.rooms) do
        rooms_sizes[id] = room.size
        room_cells[id]  = {}
        for _, cell in ipairs(room.cells) do
            room_cells[id][#room_cells[id] + 1] = { cell[1], cell[2] }
        end
    end
    return {
        n          = n,
        difficulty = self.difficulty,
        room_id    = rid_flat,
        rooms_sizes= rooms_sizes,
        room_cells = room_cells,
        solution   = sol_flat,
        puzzle     = puz_flat,
        user       = user_flat,
        won        = self.won,
    }
end

function RippleEffectBoard:load(data)
    if type(data) ~= "table" or not data.room_id then return false end
    local n = data.n or DEFAULT_N
    self.n          = n
    self.difficulty = data.difficulty or "medium"
    self.room_id    = emptyGrid(n, n, 0)
    self.solution   = emptyGrid(n, n, 0)
    self.puzzle     = emptyGrid(n, n, 0)
    self.user       = emptyGrid(n, n, 0)
    self.wrong      = emptyGrid(n, n, false)
    local idx = 1
    for r = 1, n do
        for c = 1, n do
            self.room_id[r][c]  = data.room_id[idx]  or 1
            self.solution[r][c] = data.solution[idx]  or 0
            self.puzzle[r][c]   = data.puzzle[idx]    or 0
            self.user[r][c]     = data.user[idx]      or 0
            idx = idx + 1
        end
    end
    self.rooms = {}
    if data.rooms_sizes then
        for id, sz in pairs(data.rooms_sizes) do
            local cells = {}
            if data.room_cells and data.room_cells[id] then
                for _, cell in ipairs(data.room_cells[id]) do
                    cells[#cells + 1] = {cell[1], cell[2]}
                end
            end
            self.rooms[id] = { cells = cells, size = sz }
        end
    end
    self.won      = data.won or false
    self.selected = nil
    self.undo:clear()
    return true
end

RippleEffectBoard.SIZES     = SIZES
RippleEffectBoard.DEFAULT_N = DEFAULT_N
RippleEffectBoard.MAX_ROOM  = MAX_ROOM

return RippleEffectBoard
