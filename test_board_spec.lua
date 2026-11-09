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

    describe("saves", function()
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
