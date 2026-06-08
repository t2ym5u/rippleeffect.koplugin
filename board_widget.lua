local Blitbuffer = require("ffi/blitbuffer")
local Geom       = require("ui/geometry")
local RenderText = require("ui/rendertext")
local Size       = require("ui/size")

local gwb            = require("grid_widget_base")
local GridWidgetBase = gwb.GridWidgetBase
local drawLine       = gwb.drawLine

-- ---------------------------------------------------------------------------
-- Colours
-- ---------------------------------------------------------------------------

local C_BG       = Blitbuffer.COLOR_WHITE
local C_LINE     = Blitbuffer.COLOR_BLACK
local C_GRID     = Blitbuffer.COLOR_GRAY_9
local C_GIVEN_BG = Blitbuffer.COLOR_GRAY_E
local C_SEL_BG   = Blitbuffer.COLOR_GRAY_D
local C_WRONG_BG = Blitbuffer.COLOR_GRAY_A
local C_NUM      = Blitbuffer.COLOR_BLACK
local C_USER_NUM = Blitbuffer.COLOR_GRAY_4

-- ---------------------------------------------------------------------------
-- RippleEffectBoardWidget
-- ---------------------------------------------------------------------------

local RippleEffectBoardWidget = GridWidgetBase:extend{
    board    = nil,
    selected = nil,  -- {r, c}
}

function RippleEffectBoardWidget:init()
    local n   = self.board and self.board.n or 5
    self.cols = n
    self.rows = n
    GridWidgetBase.init(self)
end

function RippleEffectBoardWidget:onCellTap(row, col)
    if self.onCellTap_cb then
        self.onCellTap_cb(row, col)
    end
end

function RippleEffectBoardWidget:onCellHold(row, col)
    if self.onCellHold_cb then
        self.onCellHold_cb(row, col)
    end
end

-- ---------------------------------------------------------------------------
-- paintTo
-- ---------------------------------------------------------------------------

function RippleEffectBoardWidget:paintTo(bb, x, y)
    if not self.board then return end
    self.paint_rect = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }

    local board = self.board
    local n     = board.n
    local cell  = self.dimen.w / n

    -- Background
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C_BG)

    -- Cell backgrounds
    for r = 1, n do
        for c = 1, n do
            local cx = x + math.floor((c - 1) * cell)
            local cy = y + math.floor((r - 1) * cell)
            local cw = math.ceil(cell)
            local ch = math.ceil(cell)
            local bg
            if self.selected and self.selected[1] == r and self.selected[2] == c then
                bg = C_SEL_BG
            elseif board.wrong[r][c] then
                bg = C_WRONG_BG
            elseif board.puzzle[r][c] ~= 0 then
                bg = C_GIVEN_BG
            end
            if bg then bb:paintRect(cx, cy, cw, ch, bg) end
        end
    end

    -- Thin grid lines
    local thin  = Size.line.thin  or 1
    local thick = math.max(2, math.floor(cell * 0.08))

    for i = 0, n do
        local lw = (i == 0 or i == n) and thick or thin
        drawLine(bb, x + math.floor(i * cell), y, lw, self.dimen.h, C_LINE)
        drawLine(bb, x, y + math.floor(i * cell), self.dimen.w, lw, C_LINE)
    end

    -- Thick room borders
    local reg_thick = math.max(3, math.floor(cell * 0.12))
    for r = 1, n do
        for c = 1, n do
            if c < n and board.room_id[r][c] ~= board.room_id[r][c + 1] then
                local bx = x + math.floor(c * cell) - math.floor(reg_thick / 2)
                local by = y + math.floor((r - 1) * cell)
                drawLine(bb, bx, by, reg_thick, math.ceil(cell), C_LINE)
            end
            if r < n and board.room_id[r][c] ~= board.room_id[r + 1][c] then
                local bx = x + math.floor((c - 1) * cell)
                local by = y + math.floor(r * cell) - math.floor(reg_thick / 2)
                drawLine(bb, bx, by, math.ceil(cell), reg_thick, C_LINE)
            end
        end
    end

    -- Cell numbers
    local pad   = self.number_padding or 2
    local inner = math.max(1, math.floor(cell - 2 * pad))
    local face  = self.number_face

    for r = 1, n do
        for c = 1, n do
            local v = board.user[r][c]
            if v and v > 0 then
                local cx   = x + math.floor((c - 1) * cell)
                local cy   = y + math.floor((r - 1) * cell)
                local text = tostring(v)
                local color = (board.puzzle[r][c] ~= 0) and C_NUM or C_USER_NUM
                if board.wrong[r][c] then color = C_LINE end
                local m  = RenderText:sizeUtf8Text(0, inner, face, text, true, false)
                local bx = cx + pad + math.floor((inner - m.x) / 2)
                local by = cy + pad + math.floor((inner + m.y_top - m.y_bottom) / 2)
                RenderText:renderUtf8Text(bb, bx, by, face, text, true, false, color)
            end
        end
    end
end

return RippleEffectBoardWidget
