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
end)
