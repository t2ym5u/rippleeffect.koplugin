local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase               = require("screen_base")
local MenuHelper               = require("menu_helper")
local RippleEffectBoard        = lrequire("board")
local RippleEffectBoardWidget  = lrequire("board_widget")

local GAME_RULES_EN = _([[
Ripple Effect — Rules

Fill every cell so that each outlined region contains the numbers 1 to N (where N is the region size) exactly once.

Distance constraint:
• If the same number appears twice in the same row or column, those two cells must be at least that number of cells apart.
  Example: two cells both containing 3 must have at least 3 cells (not counting themselves) between them.

Tap a cell to select it, then tap a digit to fill it in. Long-press a cell to clear it.
]])

local GAME_RULES_FR = [[
Effet de Vague — Règles

Remplissez chaque case de sorte que chaque région délimitée de taille N contienne les nombres de 1 à N exactement une fois.

Contrainte de distance :
• Si le même nombre apparaît deux fois dans la même ligne ou colonne, ces deux cases doivent être séparées d'au moins ce nombre de cases.
  Exemple : deux cases contenant toutes les deux le chiffre 3 doivent avoir au moins 3 cases entre elles dans la même ligne ou colonne.

Appuyez sur une case pour la sélectionner, puis sur un chiffre pour le placer. Appui long sur une case pour l'effacer.
]]

local RippleEffectScreen = ScreenBase:extend{}

function RippleEffectScreen:init()
    local state = self.plugin:loadState()
    local n     = self.plugin:getSetting("grid_n", RippleEffectBoard.DEFAULT_N)
    self.board  = RippleEffectBoard:new{ n = n }
    if not self.board:load(state) then
        self.board:generate(self.plugin:getSetting("difficulty", "easy"))
    end
    self.selected = nil
    ScreenBase.init(self)
end

function RippleEffectScreen:serializeState()
    return self.board:serialize()
end

function RippleEffectScreen:buildLayout()
    local is_landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("Ripple Effect"), function()
        return {
            { text = _("New game"),            callback = function() self:onNewGame() end },
            { text = self:getSizeButtonText(), callback = function() self:openSizeMenu() end },
            { text = self:getDiffButtonText(), callback = function() self:openDifficultyMenu() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    -- Digit pad 1..MAX_ROOM
    local keys = {}
    for d = 1, RippleEffectBoard.MAX_ROOM do
        local dv = d
        keys[#keys + 1] = { id = "digit_" .. d, text = tostring(d),
                            callback = function() self:onDigitKey(dv) end }
    end
    local number_pad = self:buildNumberPad(keys)

    -- Bottom bar. Five labels do not fit the landscape side panel on one
    -- row, so there they are split over two.
    local undo_btn   = { text = _("Undo"),   callback = function() self:onUndo() end }
    local erase_btn  = { text = _("Erase"),  callback = function() self:onErase() end }
    local check_btn  = { text = _("Check"),  callback = function() self:onCheck() end }
    local hint_btn   = { text = _("Hint"),   callback = function() self:onHint() end }
    local reveal_btn = { text = _("Reveal"), callback = function() self:onReveal() end }
    local action_bar = self:buildActionBar(is_landscape
        and { { undo_btn, erase_btn, check_btn }, { hint_btn, reveal_btn } }
        or  { undo_btn, erase_btn, check_btn, hint_btn, reveal_btn })

    self.status_text:setMaxWidth(self:getControlsWidth())
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        number_pad,
        VerticalSpan:new{ width = Size.span.vertical_default },
        action_bar,
    }

    -- The widget draws its own outer border, so the frame only pads.
    local frame_pad = Size.padding.large
    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    self.board_widget = RippleEffectBoardWidget:new{
        max_size       = math.min(budget_w, budget_h) - 2 * frame_pad,
        board          = self.board,
        selected       = self.selected,
        onCellTap_cb   = function(r, c) self:onCellTap(r, c) end,
        onCellHold_cb  = function(r, c) self:onCellHold(r, c) end,
    }
    local board_frame = FrameContainer:new{
        padding    = frame_pad,
        margin     = 0,
        bordersize = 0,
        self.board_widget,
    }

    if is_landscape then
        local content = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        }
        self:buildLandscapeLayout(title_bar, content)
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

function RippleEffectScreen:onCellTap(r, c)
    self.selected = { r, c }
    self.board_widget.selected = self.selected
    self.board_widget:refresh()
    self:updateStatus()
end

function RippleEffectScreen:onCellHold(r, c)
    self:onCellTap(r, c)
    self:onErase()
end

function RippleEffectScreen:onDigitKey(d)
    if not self.selected then
        self:updateStatus(_("Tap a cell first."))
        return
    end
    local r, c = self.selected[1], self.selected[2]
    local ok = self.board:setCell(r, c, d)
    if ok then
        self.plugin:saveState(self.board:serialize())
        if self.board.won then
            self:updateStatus(_("Congratulations! Puzzle solved!"))
        else
            self:updateStatus()
        end
    end
    self.board_widget:refresh()
end

function RippleEffectScreen:onErase()
    if not self.selected then return end
    local r, c = self.selected[1], self.selected[2]
    self.board:eraseCell(r, c)
    self.plugin:saveState(self.board:serialize())
    self.board_widget:refresh()
    self:updateStatus()
end

function RippleEffectScreen:onUndo()
    if self.board:undoMove() then
        self.board_widget:refresh()
        self:updateStatus()
        self.plugin:saveState(self.board:serialize())
    end
end

function RippleEffectScreen:onCheck()
    self.board:check()
    self.board_widget:refresh()
    local empty = self.board:countEmpty()
    if self.board.won then
        self:updateStatus(_("Congratulations! Puzzle solved!"))
    elseif empty > 0 then
        self:updateStatus(T(_("Check done. Empty: %1"), empty))
    else
        self:updateStatus(_("Some cells have errors."))
    end
end

function RippleEffectScreen:onReveal()
    self.board:reveal()
    self.board_widget:refresh()
    self:updateStatus(_("Solution revealed."))
    self.plugin:saveState(self.board:serialize())
end

function RippleEffectScreen:onNewGame()
    local diff = self.plugin:getSetting("difficulty", "easy")
    local n    = self.plugin:getSetting("grid_n", RippleEffectBoard.DEFAULT_N)
    self.board = RippleEffectBoard:new{ n = n }
    self.board:generate(diff)
    self.selected = nil
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function RippleEffectScreen:openSizeMenu()
    local sizes = {}
    for _, sz in ipairs(RippleEffectBoard.SIZES) do
        sizes[#sizes + 1] = { id = sz, text = sz .. "\xC3\x97" .. sz }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select size"),
        sizes     = sizes,
        current   = self.plugin:getSetting("grid_n", RippleEffectBoard.DEFAULT_N),
        parent    = self,
        on_select = function(sz)
            if sz ~= self.board.n then
                self.plugin:saveSetting("grid_n", sz)
                self:onNewGame()
            end
        end,
    }
end

function RippleEffectScreen:openDifficultyMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", "easy"),
        parent    = self,
        on_select = function(id)
            self.plugin:saveSetting("difficulty", id)
            if self.diff_button then
                self.diff_button:setText(self:getDiffButtonText(), self.diff_button.width)
            end
            self:onNewGame()
        end,
    }
end

function RippleEffectScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board.won then
        status = _("Congratulations! Puzzle solved!")
    else
        local empty = self.board:countEmpty()
        local n     = self.board.n
        local diff  = self.plugin:getSetting("difficulty", "easy")
        local label = MenuHelper.DIFFICULTY_LABELS[diff] or diff
        status = self:joinStatus(T("%1×%2", n, n), label, T(_("Empty: %1"), empty))
    end
    ScreenBase.updateStatus(self, status)
    -- Every move, hint, undo and reveal ends with a status update, so this
    -- is where the bar learns that the round ended (or was undone).
    self:refreshActionBar()
end

function RippleEffectScreen:getSizeButtonText()
    local n = self.board.n
    return T(_("Size: %1"), n .. "\xC3\x97" .. n)
end

function RippleEffectScreen:getDiffButtonText()
    local diff  = self.plugin:getSetting("difficulty", "easy")
    local label = MenuHelper.DIFFICULTY_LABELS[diff] or diff
    return T(_("Difficulty: %1"), label)
end

-- won is saved with the board; Reveal sets it too (a one-way end).
function RippleEffectScreen:isRoundOver()
    return self.board.won
end

return RippleEffectScreen
