local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("RippleEffectBoard", function()
    local Board

    setup(function()
        Board = require("board")
    end)


    -- Regression guard for the 2026-07-21 bug: independent random room sizing
    -- made large boards (esp. n=7) fall back near-100% of the time to a
    -- hardcoded 5×5 all-single-cell-rooms puzzle that silently overrides the
    -- requested n (`self.n = n2` in the fallback branch). Fixed by
    -- interleaving room growth with value assignment. These tests assert the
    -- board honors the requested n and that the solution is genuinely valid.
    local function newBoard(n, diff)
        math.randomseed(42)
        return Board:new{ n = n or 5, difficulty = diff or "medium" }
    end

    describe("construction", function()
        it("creates a 5×5 board by default", function()
            local b = Board:new()
            assert.are.equal(5, b.n)
        end)
    end)

    describe("generate", function()
        it("honors the requested n instead of falling back to 5", function()
            for _, n in ipairs(Board.SIZES) do
                math.randomseed(n * 137)
                local b = Board:new{ n = n }
                assert.are.equal(n, b.n, ("n silently downgraded for requested n=%d"):format(n))
            end
        end)

        it("each room's solution values are a permutation of 1..room size", function()
            local b = newBoard(6)
            for _, room in pairs(b.rooms) do
                local seen = {}
                for _, cell in ipairs(room.cells) do
                    local v = b.solution[cell[1]][cell[2]]
                    assert.is_true(v >= 1 and v <= room.size,
                        ("value %d out of range for room size %d"):format(v, room.size))
                    assert.is_nil(seen[v], ("duplicate value %d in room"):format(v))
                    seen[v] = true
                end
            end
        end)

        it("the solution passes the game's own validity check with zero errors", function()
            local b = newBoard(6)
            local n = b.n
            for r = 1, n do
                for c = 1, n do
                    b.user[r][c] = b.solution[r][c]
                end
            end
            b:check()
            for r = 1, n do
                for c = 1, n do
                    assert.is_false(b.wrong[r][c], ("solution cell [%d][%d] flagged wrong"):format(r, c))
                end
            end
        end)

        it("runs across all supported sizes without hanging or erroring", function()
            for _, n in ipairs(Board.SIZES) do
                math.randomseed(n * 977)
                local ok = pcall(function() Board:new{ n = n } end)
                assert.is_true(ok, ("generate failed for n=%d"):format(n))
            end
        end)
    end)

    -- 1.5.0: the room builder repairs a stuck patch locally instead of
    -- restarting the whole board (7x7 took seconds on a desktop). Guard
    -- what it must still deliver on many seeds: connected rooms of
    -- 1..size, the separation rule, a puzzle with exactly one solution
    -- (counted by a plain backtracker independent of board.lua's), fast.
    describe("generator over many seeds", function()
        local DIR4 = { {-1,0},{1,0},{0,-1},{0,1} }

        local function sepOk(g, n, r, c, v)
            for d = 1, v do
                for _, dd in ipairs(DIR4) do
                    local nr, nc = r + dd[1] * d, c + dd[2] * d
                    if nr >= 1 and nr <= n and nc >= 1 and nc <= n and g[nr][nc] == v then
                        return false
                    end
                end
            end
            return true
        end

        local function countSolutions(b, limit)
            local n, g = b.n, {}
            for r = 1, n do
                g[r] = {}
                for c = 1, n do g[r][c] = b.puzzle[r][c] end
            end
            local count = 0
            local function rec(k)
                if count >= limit then return end
                if k > n * n then count = count + 1; return end
                local r, c = math.floor((k - 1) / n) + 1, (k - 1) % n + 1
                if g[r][c] ~= 0 then return rec(k + 1) end
                local room = b.rooms[b.room_id[r][c]]
                for v = 1, room.size do
                    local free = sepOk(g, n, r, c, v)
                    if free then
                        for _, cell in ipairs(room.cells) do
                            if g[cell[1]][cell[2]] == v then free = false; break end
                        end
                    end
                    if free then
                        g[r][c] = v
                        rec(k + 1)
                        g[r][c] = 0
                    end
                end
            end
            rec(1)
            return count
        end

        it("builds valid, uniquely solvable puzzles quickly at every size and difficulty", function()
            for _, n in ipairs(Board.SIZES) do
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    local worst = 0
                    for seed = 1, 15 do
                        math.randomseed(seed * 7919 + n)
                        local t0 = os.clock()
                        local b = Board:new{ n = n, difficulty = diff }
                        worst = math.max(worst, os.clock() - t0)
                        assert.are.equal(n, b.n)
                        local cells_seen = 0
                        for id, room in ipairs(b.rooms) do
                            local vals, in_room = {}, {}
                            for _, cell in ipairs(room.cells) do
                                assert.are.equal(id, b.room_id[cell[1]][cell[2]])
                                local v = b.solution[cell[1]][cell[2]]
                                assert.is_true(v >= 1 and v <= room.size)
                                assert.is_nil(vals[v])
                                vals[v] = true
                                in_room[cell[1] * 100 + cell[2]] = true
                                cells_seen = cells_seen + 1
                            end
                            local first = room.cells[1]
                            local stack, seen, reached = { first }, { [first[1] * 100 + first[2]] = true }, 1
                            while #stack > 0 do
                                local cur = table.remove(stack)
                                for _, d in ipairs(DIR4) do
                                    local key = (cur[1] + d[1]) * 100 + cur[2] + d[2]
                                    if in_room[key] and not seen[key] then
                                        seen[key] = true
                                        reached = reached + 1
                                        stack[#stack + 1] = { cur[1] + d[1], cur[2] + d[2] }
                                    end
                                end
                            end
                            assert.are.equal(#room.cells, reached)
                        end
                        assert.are.equal(n * n, cells_seen)
                        for r = 1, n do
                            for c = 1, n do
                                local v = b.solution[r][c]
                                b.solution[r][c] = 0
                                assert.is_true(sepOk(b.solution, n, r, c, v))
                                b.solution[r][c] = v
                                local p = b.puzzle[r][c]
                                assert.is_true(p == 0 or p == v)
                            end
                        end
                        assert.are.equal(1, countSolutions(b, 2),
                            ("n=%d %s seed %d is not uniquely solvable"):format(n, diff, seed))
                    end
                    -- generous: ~0.1 s on a desktop
                    assert.is_true(worst < 1.5, ("n=%d %s took %.2f s"):format(n, diff, worst))
                end
            end
        end)
    end)

    describe("setCell / eraseCell / undoMove", function()
        it("setCell rejects a given (puzzle) cell", function()
            local b = newBoard(6)
            local r, c
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if b.puzzle[rr][cc] ~= 0 then r, c = rr, cc; goto done end
                end
            end
            ::done::
            if not r then return end
            local ok = b:setCell(r, c, 1)
            assert.is_false(ok)
        end)

        it("setCell + undoMove round-trips a non-given cell", function()
            local b = newBoard(6)
            local r, c
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if b.puzzle[rr][cc] == 0 then r, c = rr, cc; goto done end
                end
            end
            ::done::
            assert.is_not_nil(r)
            b:setCell(r, c, b.solution[r][c])
            assert.are.equal(b.solution[r][c], b.user[r][c])
            b:undoMove()
            assert.are.equal(0, b.user[r][c])
        end)
    end)

    describe("serialize / load", function()
        it("round-trips rooms, solution and user state", function()
            local b = newBoard(6)
            local data = b:serialize()
            local b2   = Board:new{ n = b.n }
            local ok   = b2:load(data)
            assert.is_true(ok)
            assert.are.equal(b.n, b2.n)
            assert.are.equal(#b.rooms, #b2.rooms)
        end)

        it("load returns false for invalid data", function()
            local b = Board:new()
            assert.is_false(b:load(nil))
            assert.is_false(b:load({}))
        end)
    end)

    -- 1.6.0: levels graded by a human-style solver, never trial and error.
    describe("difficulty levels (1.6.0)", function()
        local LEVELS = { "easy", "medium", "hard" }
        local SEEDS = 6

        it("every level is solvable without trial, within its tier", function()
            for _, n in ipairs(Board.SIZES) do
                for _, d in ipairs(LEVELS) do
                    local level = Board.LEVELS[d](n)
                    for seed = 1, SEEDS do
                        math.randomseed(seed * 131 + n)
                        local b = Board:new{ n = n, difficulty = d }
                        local ok, t2, values = Board._logicSolve(b.puzzle, b.room_id, b.rooms, n, level.tier)
                        assert.is_true(ok, n .. " " .. d .. " seed " .. seed)
                        assert.are.same(b.solution, values)
                        if d == "easy" then
                            assert.are.equal(0, t2)
                        else
                            assert.is_true(t2 >= 1, n .. " " .. d .. " needs tier 2")
                        end
                    end
                end
            end
        end)

        it("levels are distinct: fewer givens and more tier-2 steps as they go up", function()
            for _, n in ipairs(Board.SIZES) do
                local giv, t2s = {}, {}
                for li, d in ipairs(LEVELS) do
                    giv[li], t2s[li] = 0, 0
                    for seed = 1, SEEDS do
                        math.randomseed(seed * 71 + n)
                        local b = Board:new{ n = n, difficulty = d }
                        local _, t2 = Board._logicSolve(b.puzzle, b.room_id, b.rooms, n, 2)
                        t2s[li] = t2s[li] + t2
                        for r = 1, n do
                            for c = 1, n do
                                if b.puzzle[r][c] ~= 0 then giv[li] = giv[li] + 1 end
                            end
                        end
                    end
                end
                assert.is_true(giv[1] > giv[2] and giv[2] > giv[3], "givens n=" .. n)
                assert.is_true(t2s[1] < t2s[2] and t2s[2] < t2s[3], "tier-2 steps n=" .. n)
            end
        end)

        it("the solver never settles an ambiguous grid", function()
            -- Random partial grids: whenever the solver finishes one, the
            -- brute-force counter finds exactly one solution.
            local solved = 0
            for seed = 1, 60 do
                math.randomseed(seed * 3)
                local n = Board.SIZES[seed % #Board.SIZES + 1]
                local b = Board:new{ n = n, difficulty = "easy" }
                local p, density = {}, (seed % 4) * 0.1
                for r = 1, n do
                    p[r] = {}
                    for c = 1, n do
                        p[r][c] = math.random() < density and b.solution[r][c] or 0
                    end
                end
                local ok, _, values = Board._logicSolve(p, b.room_id, b.rooms, n, 2)
                if ok then
                    solved = solved + 1
                    local count, exhausted = Board._countSolutions(p, b.room_id, b.rooms, n, 2, 1e7)
                    assert.is_false(exhausted)
                    assert.are.equal(1, count)
                    assert.are.same(b.solution, values)
                end
            end
            assert.is_true(solved >= 10, "solved " .. solved)
        end)

        it("gives the same puzzle for the same seed", function()
            math.randomseed(2026); local a = Board:new{ n = 6, difficulty = "hard" }
            math.randomseed(2026); local b = Board:new{ n = 6, difficulty = "hard" }
            assert.are.same(a.solution, b.solution)
            assert.are.same(a.puzzle, b.puzzle)
            assert.are.same(a.room_id, b.room_id)
        end)

        it("loads a save made by 1.5.2", function()
            local data = { difficulty = "hard", n = 5, puzzle = {0,0,4,0,0,1,0,1,0,0,0,0,0,0,0,0,0,0,2,0,0,1,0,0,2}, room_cells = {{{1,1},{2,1},{3,1}},{{1,2}},{{2,3},{2,4},{1,3},{2,5}},{{1,5},{1,4}},{{2,2},{3,2}},{{3,3},{3,4}},{{4,5},{5,5},{3,5}},{{4,1}},{{5,3},{5,2},{4,2},{5,1}},{{4,3}},{{5,4},{4,4}}}, room_id = {1,2,3,4,4,1,5,3,3,3,1,5,6,6,7,8,9,10,11,7,9,9,9,11,7}, rooms_sizes = {3,1,4,2,2,2,3,1,4,1,2}, solution = {2,1,4,2,1,1,2,1,3,2,3,1,2,1,3,1,4,1,2,1,2,1,3,1,2}, user = {2,0,4,0,0,1,0,1,0,0,0,0,0,0,0,0,0,0,2,0,0,1,0,0,2}, won = false }
            local b = Board:new{ empty = true }
            assert.is_true(b:load(data))
            assert.are.equal("hard", b.difficulty)
            assert.are.equal(2, b.user[1][1])
            assert.are.equal(4, b.rooms[3].size)
            assert.is_true(b:setCell(1, 2, 1))
        end)
    end)
end)
