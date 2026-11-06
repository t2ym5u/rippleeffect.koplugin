local grid_utils = require("grid_utils")
local UndoStack  = require("undo_stack")
local Hint      = require("hint")
local bit       = require("bit")

local emptyGrid = grid_utils.emptyGrid
local copyGrid  = grid_utils.copyGrid
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
    -- Only cells within reach (distance <= v) can clash.
    local row = grid[r]
    local lo, hi = c - v, c + v
    if lo < 1 then lo = 1 end
    if hi > n then hi = n end
    for cc = lo, hi do
        if cc ~= c and row[cc] == v then return false end
    end
    lo, hi = r - v, r + v
    if lo < 1 then lo = 1 end
    if hi > n then hi = n end
    for rr = lo, hi do
        if rr ~= r and grid[rr][c] == v then return false end
    end
    return true
end

-- Gives the cells of `shape` (k of them, from the i-th on) the values 1..k
-- in some order that passes the separation rule against the values already
-- on the board (plain backtracking, values tried in increasing order; at
-- most 4! orders). Leaves the cells at 0 when no order fits. A plain
-- function rather than a closure: it runs thousands of times per board, and
-- LuaJIT cannot compile code that creates closures.
local function placeValues(grid, n, shape, k, i, used)
    if i > k then return true end
    local rc = shape[i]
    local r, c = rc[1], rc[2]
    local row = grid[r]
    for v = 1, k do
        if not used[v] and isValidGlobal(grid, n, r, c, v) then
            used[v] = true
            row[c] = v
            if placeValues(grid, n, shape, k, i + 1, used) then return true end
            row[c] = 0
            used[v] = false
        end
    end
    return false
end

-- Build rooms AND assign their values in the same pass instead of
-- generating a blind random room layout and hoping a separate solve() can
-- fill it (the old generate-then-solve approach had to prove a full random
-- layout infeasible before retrying -- empirically needing many thousands
-- of attempts at n=6/7). Each new room first grows its shape over free
-- cells, then looks for an order of 1..size that fits the values already on
-- the board, dropping its last cell until one does. Cells left over are
-- patched in a repair pass: join an adjacent room (its values re-ordered to
-- fit), or become a size-1 room.
--
-- When the repair pass gets stuck, only the rooms around the stuck cell are
-- cleared and that patch is rebuilt, up to LOCAL_RETRIES times before the
-- caller starts a whole new board. The old builder restarted the whole
-- board every time and needed ~30000 restarts per 7x7 board (seconds on a
-- desktop, over a minute on a Kobo, and a static fallback board in ~8% of
-- games); now a few restarts at most.
local ROOM_SIZE_WEIGHTS = { 1, 1, 2, 2, 2, 3, 3, 4 }
local LOCAL_RETRIES = 150

local function tryGenerateRoomsAndValues(n)
    local grid    = emptyGrid(n, n, 0)
    local room_id = emptyGrid(n, n, 0)
    local rooms   = {}
    local next_room = 0

    -- Gives the cells of `shape` the values 1..#shape in some order that
    -- passes the separation rule against the values already on the board
    -- (plain backtracking, values tried in increasing order; at most 4!
    -- orders). Leaves the shape's cells at 0 when no order fits.
    local used = {}
    local function assignValues(shape)
        local k = #shape
        for v = 1, k do used[v] = false end
        return placeValues(grid, n, shape, k, 1, used)
    end

    -- Scratch lists of the cells a growing room may take next (duplicates
    -- kept: a cell next to two of the room's cells is twice as likely).
    local cand_r, cand_c = {}, {}
    local function growRoom(r, c)
        local target = ROOM_SIZE_WEIGHTS[math.random(#ROOM_SIZE_WEIGHTS)]
        local shape = { {r, c} }
        local ns = 1
        while ns < target do
            local nc_ = 0
            for s_ = 1, ns do
                local rc = shape[s_]
                local sr_, sc_ = rc[1], rc[2]
                for d_ = 1, 4 do
                    local d = DIR4[d_]
                    local nr, nc = sr_ + d[1], sc_ + d[2]
                    if nr >= 1 and nr <= n and nc >= 1 and nc <= n
                            and room_id[nr][nc] == 0 then
                        local inside = false
                        for t_ = 1, ns do
                            local q = shape[t_]
                            if q[1] == nr and q[2] == nc then inside = true; break end
                        end
                        if not inside then
                            nc_ = nc_ + 1
                            cand_r[nc_], cand_c[nc_] = nr, nc
                        end
                    end
                end
            end
            if nc_ == 0 then break end
            local p = math.random(nc_)
            ns = ns + 1
            shape[ns] = { cand_r[p], cand_c[p] }
        end

        while #shape > 0 and not assignValues(shape) do
            shape[#shape] = nil
        end
        if #shape > 0 then
            next_room = next_room + 1
            for _, rc in ipairs(shape) do room_id[rc[1]][rc[2]] = next_room end
            rooms[next_room] = { cells = shape, size = #shape }
        end
    end

    -- Repair: (r, c) joins an adjacent room, re-ordering that room's values
    -- so the new cell fits, or becomes a size-1 room. False if neither.
    local function patchCell(r, c)
        local tried = {}
        for _, d in ipairs(DIR4) do
            local nr, nc = r + d[1], c + d[2]
            local id = inBounds(nr, nc, n) and room_id[nr][nc] or 0
            if id > 0 and not tried[id] and rooms[id].size < MAX_ROOM then
                tried[id] = true
                local room = rooms[id]
                local saved = {}
                for i, rc in ipairs(room.cells) do
                    saved[i] = grid[rc[1]][rc[2]]
                    grid[rc[1]][rc[2]] = 0
                end
                local shape = {}
                for i, rc in ipairs(room.cells) do shape[i] = rc end
                shape[#shape + 1] = {r, c}
                if assignValues(shape) then
                    room.cells = shape
                    room.size  = #shape
                    room_id[r][c] = id
                    return true
                end
                for i, rc in ipairs(room.cells) do grid[rc[1]][rc[2]] = saved[i] end
            end
        end
        if isValidGlobal(grid, n, r, c, 1) then
            next_room = next_room + 1
            room_id[r][c] = next_room
            grid[r][c]    = 1
            rooms[next_room] = { cells = {{r, c}}, size = 1 }
            return true
        end
        return false
    end

    -- Grows rooms from the free cells of `order`, then patches what is
    -- left. Returns the cell it got stuck on, or nil when the board is full.
    local function fill(order)
        for _, cell in ipairs(order) do
            if room_id[cell[1]][cell[2]] == 0 then growRoom(cell[1], cell[2]) end
        end
        for r = 1, n do
            for c = 1, n do
                if room_id[r][c] == 0 and not patchCell(r, c) then return r, c end
            end
        end
    end

    local all_cells = {}
    for r = 1, n do
        for c = 1, n do all_cells[#all_cells + 1] = {r, c} end
    end
    shuffle(all_cells)

    local sr, sc = fill(all_cells)
    local retries = 0
    while sr do
        retries = retries + 1
        if retries > LOCAL_RETRIES then return nil end
        -- Clear every room that touches the stuck cell's 3x3 block, then
        -- rebuild the free patch in a fresh random order.
        for dr = -1, 1 do
            for dc = -1, 1 do
                local r, c = sr + dr, sc + dc
                local id = inBounds(r, c, n) and room_id[r][c] or 0
                if id > 0 then
                    for _, rc in ipairs(rooms[id].cells) do
                        room_id[rc[1]][rc[2]] = 0
                        grid[rc[1]][rc[2]]    = 0
                    end
                    rooms[id] = nil
                end
            end
        end
        local free = {}
        for r = 1, n do
            for c = 1, n do
                if room_id[r][c] == 0 then free[#free + 1] = {r, c} end
            end
        end
        shuffle(free)
        sr, sc = fill(free)
    end

    -- Renumber the surviving rooms 1..k in board order.
    local renum, out = {}, {}
    for r = 1, n do
        for c = 1, n do
            local id = room_id[r][c]
            if not renum[id] then
                out[#out + 1] = rooms[id]
                renum[id] = #out
            end
            room_id[r][c] = renum[id]
        end
    end
    return grid, room_id, out
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

-- Counts solutions (up to `limit`) of the room+ripple-rule instance given
-- the current puzzle's fixed cells, using MRV cell ordering. Returns
-- (solutions_found, exhausted); exhausted=true means node_budget was hit
-- before the search concluded, so the count isn't proof. Mirrors
-- sudokukiller.koplugin/board.lua's countCageSolutions.
-- Since 1.6.0 the generator digs with logicSolve (below), which proves
-- uniqueness by itself; this counter stays as an independent check for
-- the specs.

local function countSolutions(puzzle, room_id, rooms, n, limit, node_budget)
    local grid = {}
    for r = 1, n do
        grid[r] = {}
        for c = 1, n do grid[r][c] = puzzle[r][c] end
    end

    local solutions, nodes, exhausted = 0, 0, false

    local function isValid(r, c, v)
        local id = room_id[r][c]
        local room = rooms[id]
        if v > room.size then return false end
        for _, cell in ipairs(room.cells) do
            local cr, cc = cell[1], cell[2]
            if not (cr == r and cc == c) and grid[cr][cc] == v then return false end
        end
        for cc = 1, n do
            if cc ~= c and grid[r][cc] == v and math.abs(cc - c) <= v then return false end
        end
        for rr = 1, n do
            if rr ~= r and grid[rr][c] == v and math.abs(rr - r) <= v then return false end
        end
        return true
    end

    local empties = {}
    for r = 1, n do for c = 1, n do if grid[r][c] == 0 then empties[#empties + 1] = { r = r, c = c } end end end

    local function candidatesFor(r, c)
        local room = rooms[room_id[r][c]]
        local cands = {}
        for v = 1, room.size do if isValid(r, c, v) then cands[#cands + 1] = v end end
        return cands
    end

    local function search(depth)
        if solutions >= limit or exhausted then return end
        nodes = nodes + 1
        if nodes > node_budget then exhausted = true; return end
        if depth > #empties then solutions = solutions + 1; return end
        local best_idx, best_cands, best_len = nil, nil, 1000
        for i, cell in ipairs(empties) do
            if grid[cell.r][cell.c] == 0 then
                local cands = candidatesFor(cell.r, cell.c)
                if #cands < best_len then
                    best_len, best_cands, best_idx = #cands, cands, i
                    if best_len <= 1 then break end
                end
            end
        end
        if best_idx == nil then solutions = solutions + 1; return end
        if best_len == 0 then return end
        local cell = empties[best_idx]
        for _, v in ipairs(best_cands) do
            grid[cell.r][cell.c] = v
            search(depth + 1)
            grid[cell.r][cell.c] = 0
            if solutions >= limit or exhausted then return end
        end
    end
    search(1)
    return solutions, exhausted
end

-- ---------------------------------------------------------------------------
-- Human-style solver (1.6.0), used to grade and dig puzzles
-- ---------------------------------------------------------------------------
--
-- Keeps the digits still possible in every cell (bit v-1 for digit v) and
-- narrows them down without trial and error:
--   tier 1  what a beginner does:
--           - a placed digit is crossed out of its room and of the four
--             cells touching it (equal digits never touch);
--           - a cell with one digit left takes it;
--           - a digit with one place left in its room goes there.
--   tier 2  - the long reach of a placed 2, 3 or 4: the same digit cannot
--             appear 2..v cells away in its row or column (counting cells
--             along a line);
--           - "pointing": every place left for digit v in a room is
--             within reach (v cells or fewer, same row or column) of the
--             same outside cell, so that cell is not v;
--           - pairs and triples inside a room: two cells holding the same
--             two digits (three cells, three digits) take them away from
--             the rest of the room, and two digits that only fit in the
--             same two cells clear those cells of everything else.
-- Tier 2 is only tried when tier 1 is stuck, and each tier-2 step counts:
-- that count tells the levels apart. A puzzle it finishes has exactly one
-- solution, since every step only follows from the rules.
local POP, LOW, BIT = {}, {}, {}
for v = 1, MAX_ROOM do BIT[v] = bit.lshift(1, v - 1) end
for m = 0, BIT[MAX_ROOM] * 2 - 1 do
    local k, lo = 0, 0
    for v = 1, MAX_ROOM do
        if bit.band(m, BIT[v]) ~= 0 then
            k = k + 1
            if lo == 0 then lo = v end
        end
    end
    POP[m], LOW[m] = k, lo
end

-- The parts of a layout the solver needs, built once per layout: cell
-- index (r-1)*n+c, each room's cells (rooms numbered 1..k in the order
-- of their ids), each cell's room, the other cells of its row and column
-- with their distance, and row/column for quick reach tests.
local function prepare(room_id, rooms, n)
    local ctx = { n = n, N = n * n, units = {}, size = {}, cage_of = {}, nbr = {}, dist = {}, row = {}, col = {} }
    local ids = {}
    for id in pairs(rooms) do ids[#ids + 1] = id end
    table.sort(ids)
    local slot = {}
    for k, id in ipairs(ids) do
        local u = {}
        for q, rc in ipairs(rooms[id].cells) do u[q] = (rc[1] - 1) * n + rc[2] end
        ctx.units[k] = u
        ctx.size[k] = rooms[id].size
        slot[id] = k
    end
    for r = 1, n do
        for c = 1, n do
            local i = (r - 1) * n + c
            ctx.cage_of[i] = slot[room_id[r][c]]
            ctx.row[i], ctx.col[i] = r, c
            local list, dist = {}, {}
            for k = 1, n do
                if k ~= c then list[#list + 1] = (r - 1) * n + k; dist[#list] = math.abs(k - c) end
                if k ~= r then list[#list + 1] = (k - 1) * n + c; dist[#list] = math.abs(k - r) end
            end
            ctx.nbr[i], ctx.dist[i] = list, dist
        end
    end
    return ctx
end

-- puzzle: grid of digits (0 = empty). Returns solved, t2_steps, values
-- (grid, 0 where still open). (Internally rooms are "cages".)
local function solveCtx(puzzle, ctx, max_tier)
    local n, N = ctx.n, ctx.N
    local units, size, cage_of, nbr, dist, row, col = ctx.units, ctx.size, ctx.cage_of, ctx.nbr, ctx.dist, ctx.row, ctx.col
    local nunits = #units
    local band, bnot, bor = bit.band, bit.bnot, bit.bor
    local dom = {}
    for r = 1, n do
        for c = 1, n do
            local i = (r - 1) * n + c
            local v = puzzle[r][c]
            dom[i] = v > 0 and BIT[v] or BIT[size[cage_of[i]]] * 2 - 1
        end
    end
    local done, bad = {}, false
    local function removeMask(j, m)
        local old = dom[j]
        local new = band(old, bnot(m))
        if new ~= old then
            dom[j] = new
            if new == 0 then bad = true end
            return true
        end
        return false
    end

    local function tier1()
        local prog = false
        for i = 1, N do
            local m = dom[i]
            if not done[i] and POP[m] == 1 then
                done[i] = true
                prog = true
                local u = units[cage_of[i]]
                for k = 1, #u do
                    local j = u[k]
                    if j ~= i then removeMask(j, m) end
                end
                local nb, ds = nbr[i], dist[i]
                for k = 1, #nb do
                    if ds[k] == 1 then removeMask(nb[k], m) end
                end
            end
        end
        if prog or bad then return prog end
        for id = 1, nunits do
            local u = units[id]
            for v = 1, size[id] do
                local b = BIT[v]
                local cnt, last = 0, nil
                for k = 1, #u do
                    if band(dom[u[k]], b) ~= 0 then cnt = cnt + 1; last = u[k] end
                end
                if cnt == 0 then bad = true; return false end
                if cnt == 1 and dom[last] ~= b then dom[last] = b; return true end
            end
        end
        return false
    end

    -- Would digit v in cell p rule v out of cell x?
    local function reach(x, p, v)
        if x == p then return false end
        if row[x] == row[p] then return math.abs(col[x] - col[p]) <= v end
        if col[x] == col[p] then return math.abs(row[x] - row[p]) <= v end
        return false
    end

    local places, far_done = {}, {}
    local function tier2()
        -- The long reach of a placed 2, 3 or 4: no equal digit 2..v cells
        -- away in its row or column. One placed digit per step.
        for i = 1, N do
            local m = dom[i]
            if not far_done[i] and POP[m] == 1 then
                far_done[i] = true
                local v = LOW[m]
                if v >= 2 then
                    local nb, ds = nbr[i], dist[i]
                    local ch = false
                    for k = 1, #nb do
                        local d = ds[k]
                        if d >= 2 and d <= v and removeMask(nb[k], m) then ch = true end
                    end
                    if ch then return true end
                end
            end
        end
        -- Pointing.
        for id = 1, nunits do
            local u = units[id]
            for v = 1, size[id] do
                local b = BIT[v]
                local np, placed = 0, false
                for k = 1, #u do
                    local j = u[k]
                    local m = dom[j]
                    if band(m, b) ~= 0 then
                        if m == b then placed = true end
                        np = np + 1
                        places[np] = j
                    end
                end
                if not placed and np >= 2 then
                    local ch = false
                    local nb, ds = nbr[places[1]], dist[places[1]]
                    for k = 1, #nb do
                        local x = nb[k]
                        if ds[k] <= v and cage_of[x] ~= id and band(dom[x], b) ~= 0 then
                            local all = true
                            for q = 2, np do
                                if not reach(x, places[q], v) then all = false; break end
                            end
                            if all then removeMask(x, b); ch = true end
                        end
                    end
                    if ch then return true end
                end
            end
        end
        -- Subsets inside a room.
        for id = 1, nunits do
            local u = units[id]
            local nu = #u
            if nu >= 3 then
                for x = 1, nu do
                    local mx = dom[u[x]]
                    if POP[mx] > 1 then
                        for y = x + 1, nu do
                            local my = dom[u[y]]
                            if POP[my] > 1 then
                                local m2 = bor(mx, my)
                                if POP[m2] == 2 then
                                    local ch = false
                                    for z = 1, nu do
                                        if z ~= x and z ~= y and removeMask(u[z], m2) then ch = true end
                                    end
                                    if ch then return true end
                                elseif POP[m2] == 3 then
                                    for w = y + 1, nu do
                                        local mw = dom[u[w]]
                                        if POP[mw] > 1 and POP[bor(m2, mw)] == 3 then
                                            local m3 = bor(m2, mw)
                                            local ch = false
                                            for z = 1, nu do
                                                if z ~= x and z ~= y and z ~= w and removeMask(u[z], m3) then ch = true end
                                            end
                                            if ch then return true end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
                -- Hidden pairs.
                local sz = size[id]
                for v = 1, sz do
                    for w = v + 1, sz do
                        local bm = bor(BIT[v], BIT[w])
                        local hits, h1, h2, both = 0, nil, nil, true
                        for k = 1, nu do
                            local m = band(dom[u[k]], bm)
                            if m ~= 0 then
                                hits = hits + 1
                                if hits == 1 then h1 = u[k] else h2 = u[k] end
                                if m ~= bm then both = false end
                            end
                        end
                        if hits == 2 and both and (dom[h1] ~= bm or dom[h2] ~= bm) then
                            dom[h1], dom[h2] = bm, bm
                            return true
                        end
                    end
                end
            end
        end
        return false
    end

    local t2 = 0
    while not bad do
        if not tier1() then
            if bad then break end
            local solved = true
            for i = 1, N do if POP[dom[i]] ~= 1 then solved = false; break end end
            if solved then break end
            if max_tier >= 2 and tier2() then t2 = t2 + 1 else break end
        end
    end
    local values, solved = {}, not bad
    for r = 1, n do
        values[r] = {}
        for c = 1, n do
            local m = dom[(r - 1) * n + c]
            if POP[m] == 1 then values[r][c] = LOW[m] else values[r][c] = 0; solved = false end
        end
    end
    return solved, t2, values
end

local function logicSolve(puzzle, room_id, rooms, n, max_tier)
    return solveCtx(puzzle, prepare(room_id, rooms, n), max_tier)
end

-- What each level asks for (1.6.0). Before, digging only checked that the
-- answer stayed unique and levels differed only by how many digits were
-- left: almost every puzzle, at every level, fell to the same simple
-- steps, and a few (7x7 Hard: 3%) needed trial and error.
--   tier          the hardest reasoning the puzzle may need (see logicSolve)
--   min_given     never show fewer digits than this fraction of the grid
--   min_t2/max_t2 how many tier-2 steps the solution needs
-- Easy: tier 1 only. Medium: a few tier-2 steps. Hard: fewer digits, more
-- tier-2 steps. Never trial and error.
local LEVELS = {
    easy   = function(n) return { tier = 1, min_given = 0.40, min_t2 = 0, max_t2 = 0 } end,
    medium = function(n) return { tier = 2, min_given = 0.25, min_t2 = 1, max_t2 = n - 1 } end,
    hard   = function(n) return { tier = 2, min_given = 0.0, min_t2 = n - 2, max_t2 = math.huge } end,
}

-- Digs one candidate: digits hidden in a random order, each one only if
-- the solver at the level's tier still finishes the grid. Returns the
-- puzzle and its tier-2 step count.
local function removeClues(solution, room_id, rooms, n, level, on_progress)
    local puzzle = emptyGrid(n, n, 0)
    for r = 1, n do
        for c = 1, n do puzzle[r][c] = solution[r][c] end
    end
    local removable = {}
    for r = 1, n do
        for c = 1, n do removable[#removable + 1] = {r, c} end
    end
    shuffle(removable)
    local total = n * n
    local floor_given = math.ceil(total * level.min_given)
    local shown = total
    local ctx = prepare(room_id, rooms, n)
    for i, cell in ipairs(removable) do
        if shown <= floor_given then break end
        if on_progress then on_progress(i / total) end
        local r, c = cell[1], cell[2]
        puzzle[r][c] = 0
        if solveCtx(puzzle, ctx, level.tier) then
            shown = shown - 1
        else
            puzzle[r][c] = solution[r][c]
        end
    end
    local _, t2 = solveCtx(puzzle, ctx, 2)
    return puzzle, t2
end

-- ---------------------------------------------------------------------------
-- Static fallback boards
-- ---------------------------------------------------------------------------

-- Before 1.5.0, tryGenerateRoomsAndValues could exhaust MAX_ATTEMPTS
-- without completing a full room layout -- measured empirically at roughly
-- 1 success per ~30000 attempts at n=7, a ~8% chance of exhausting a
-- 100000-attempt budget. With the local repairs it now needs a handful of
-- attempts at most, so this is a pure safety net. The previous fallback built an all-1s grid of
-- single-cell rooms, which VIOLATES the game's own separation rule (every
-- adjacent same-value pair needs to be more than value cells apart, but
-- distance 1 everywhere breaks that for value 1) and silently shrank the
-- board to 5x5 regardless of the size the player picked.
--
-- These are real, pre-verified valid boards -- built by running
-- tryGenerateRoomsAndValues offline until it produced a layout that passes
-- every room-uniqueness and separation check -- kept as a last-resort
-- substitute so a rare generation failure still yields a rule-correct board
-- at the size the player actually requested, instead of a broken one.
local FALLBACK_BOARDS = {
    [5] = {
        grid = {
            {1,3,1,2,1},
            {3,1,2,1,3},
            {1,2,1,4,1},
            {2,1,3,1,2},
            {1,4,1,3,1},
        },
        room_id = {
            {8,3,10,6,13},
            {1,3,3,6,6},
            {1,1,4,6,12},
            {7,7,7,5,2},
            {9,7,11,2,2},
        },
    },
    [6] = {
        grid = {
            {1,2,1,3,2,1},
            {3,1,2,1,3,4},
            {1,4,1,2,1,3},
            {2,1,4,1,2,1},
            {1,2,1,3,1,2},
            {3,1,2,1,3,1},
        },
        room_id = {
            {4,4,1,2,2,2},
            {17,13,1,3,3,3},
            {17,17,7,3,5,5},
            {17,11,12,16,5,14},
            {9,8,12,12,10,10},
            {8,8,12,6,10,15},
        },
    },
    [7] = {
        grid = {
            {3,1,2,1,3,1,2},
            {1,3,4,2,1,3,1},
            {2,1,3,1,2,1,3},
            {1,2,1,4,1,2,1},
            {3,1,2,1,3,1,2},
            {1,3,1,2,1,3,1},
            {2,1,4,1,2,1,3},
        },
        room_id = {
            {3,3,3,11,2,8,7},
            {6,14,3,2,2,7,7},
            {21,14,5,5,5,19,19},
            {21,14,18,5,13,19,4},
            {21,20,12,12,12,22,22},
            {17,16,10,10,23,22,1},
            {16,16,16,9,15,15,15},
        },
    },
}

-- Rebuilds the {cells=, size=} rooms table from a grid + room_id pair --
-- size is recovered as the max value written in that room, which always
-- equals its cell count for a valid layout (values are exactly 1..size).
local function buildRoomsFromRoomId(grid, room_id, n)
    local rooms = {}
    for r = 1, n do
        for c = 1, n do
            local id = room_id[r][c]
            local room = rooms[id]
            if not room then
                room = { cells = {}, size = 0 }
                rooms[id] = room
            end
            room.cells[#room.cells + 1] = { r, c }
            if grid[r][c] > room.size then room.size = grid[r][c] end
        end
    end
    return rooms
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
    -- opts.empty: the caller loads a save or generates right after, so
    -- skip the throwaway puzzle.
    if not opts.empty then obj:generate() end
    return obj
end

-- on_progress (optional): called with a 0..1 fraction as it goes.
function RippleEffectBoard:generate(diff, on_progress)
    self.difficulty = diff or self.difficulty
    local n = self.n
    -- Each attempt is a constructive build with local repairs (no search
    -- over the whole board): measured at n=7 (the hardest supported size)
    -- over 2000 seeds, at most 12 attempts.
    local MAX_ATTEMPTS = 2000

    local level = (LEVELS[self.difficulty] or LEVELS.medium)(n)
    -- Up to CANDIDATES dug puzzles until one needs a number of tier-2
    -- steps in the level's range; otherwise the closest one. Each layout
    -- is dug in up to ORDERS different random orders before a new one is
    -- built (building a layout costs more than digging it). Every
    -- candidate is finished by logicSolve without trial, so any of them is
    -- a valid, unique puzzle. Bounded by attempt counts only: same seed,
    -- same puzzle on every device.
    local candidates = RippleEffectBoard.CANDIDATES[n] or 6
    local orders = RippleEffectBoard.ORDERS[n] or 4
    local best, best_miss, made = nil, nil, 0
    for attempt = 1, MAX_ATTEMPTS do
        local grid, room_id, rooms = tryGenerateRoomsAndValues(n)
        if grid then
            for _ = 1, orders do
                made = made + 1
                local puzzle, t2 = removeClues(grid, room_id, rooms, n, level,
                    on_progress and function(f) on_progress((made - 1 + f) / candidates) end)
                local miss = 0
                if t2 < level.min_t2 then miss = level.min_t2 - t2
                elseif t2 > level.max_t2 then miss = t2 - level.max_t2 end
                if not best or miss < best_miss then
                    best = { grid = grid, room_id = room_id, rooms = rooms,
                             puzzle = puzzle, t2 = t2, attempt = made }
                    best_miss = miss
                end
                if miss == 0 or made >= candidates then break end
            end
            if best_miss == 0 or made >= candidates then break end
        end
    end
    if best then
        self.room_id  = best.room_id
        self.rooms    = best.rooms
        self.solution = best.grid
        self.puzzle   = best.puzzle
        -- How the kept puzzle graded (not saved; read by the specs).
        self.grade    = { t2 = best.t2, attempt = best.attempt }
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
        if on_progress then on_progress(1) end
        return
    end

    -- Fallback: MAX_ATTEMPTS exhausted without a full room layout (see
    -- FALLBACK_BOARDS comment above). Use a pre-verified valid board at the
    -- size the player actually requested rather than a broken one.
    local fb      = FALLBACK_BOARDS[n] or FALLBACK_BOARDS[DEFAULT_N]
    local sol     = copyGrid(fb.grid, n, n)
    local room_id = copyGrid(fb.room_id, n, n)
    local rooms   = buildRoomsFromRoomId(sol, room_id, n)
    self.n        = n
    self.room_id  = room_id
    self.rooms    = rooms
    self.solution = sol
    self.puzzle   = removeClues(sol, room_id, rooms, n, level)
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

-- Givens are the non-zero cells of `puzzle`; setCell already refuses those
-- and accepts 0 as "empty", so no clearCell is needed.
Hint.install(RippleEffectBoard, {
    getUser     = function(b, r, c) return b.user[r][c] end,
    getSolution = function(b, r, c) return b.solution[r][c] end,
    isGiven     = function(b, r, c) return b.puzzle[r][c] ~= 0 end,
    setCell     = function(b, r, c, v) return b:setCell(r, c, v) end,
    blank       = 0,
})

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
RippleEffectBoard.LEVELS    = LEVELS
-- Dug candidates per puzzle, by size, and dig orders per layout (see
-- generate).
RippleEffectBoard.CANDIDATES = { [5] = 24, [6] = 16, [7] = 12 }
RippleEffectBoard.ORDERS     = { [5] = 4, [6] = 8, [7] = 12 }
-- for the specs
RippleEffectBoard._logicSolve     = logicSolve
RippleEffectBoard._countSolutions = countSolutions

return RippleEffectBoard
