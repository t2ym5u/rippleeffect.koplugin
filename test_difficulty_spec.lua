-- Difficulty guarantees for Ripple Effect: every size x level builds a
-- valid, unique puzzle quickly, the game's logic solver finishes it without
-- trial within the level's tier, Easy needs tier 1 only, levels are ordered
-- (fewer givens, more tier-2 steps), and a seed gives the same puzzle
-- without reading the clock.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

-- Runs fn with os.clock/os.time/os.date replaced by functions that fail:
-- a generator must bound its work by counts, never by time.
local function withoutClock(fn)
    local oc, ot, od = os.clock, os.time, os.date
    local function boom(name) return function() error("generator read " .. name, 2) end end
    os.clock, os.time, os.date = boom("os.clock"), boom("os.time"), boom("os.date")
    local ok, err = pcall(fn)
    os.clock, os.time, os.date = oc, ot, od
    if not ok then error(err, 0) end
end

describe("Ripple Effect difficulty", function()
    local Board

    setup(function()
        Board = require("board")
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

        it("generation never reads the clock", function()
            for _, n in ipairs(Board.SIZES) do
                for _, d in ipairs(LEVELS) do
                    math.randomseed(n * 17)
                    withoutClock(function() Board:new{ n = n, difficulty = d } end)
                end
            end
        end)
    end)
end)
