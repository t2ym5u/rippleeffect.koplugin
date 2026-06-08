local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local ButtonTable     = require("ui/widget/buttontable")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("gettext")
local T               = require("ffi/util").template

local ScreenBase               = require("screen_base")
local MenuHelper               = require("menu_helper")
local RippleEffectBoard        = lrequire("board")
local RippleEffectBoardWidget  = lrequire("board_widget")

local DeviceScreen = Device.screen

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
    local sw           = DeviceScreen:getWidth()
    local is_landscape = self:isLandscape()

    self.board_widget = RippleEffectBoardWidget:new{
        board           = self.board,
        onCellTap_cb    = function(r, c) self:onCellTap(r, c) end,
        onCellHold_cb   = function(r, c) self:onCellHold(r, c) end,
    }

    local board_frame = FrameContainer:new{
        padding = Size.padding.large,
        margin  = Size.margin.default,
        self.board_widget,
    }

    local board_frame_size  = self.board_widget.size + (Size.padding.large + Size.margin.default) * 2
    local right_panel_width = sw - board_frame_size - Size.span.horizontal_default
    local button_width = is_landscape
        and math.max(right_panel_width - Size.span.horizontal_default, 100)
        or  math.floor(sw * 0.9)

    local top_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = button_width,
        buttons = {{
            { text = _("New"),      callback = function() self:onNewGame() end },
            { id = "size_button",   text = self:getSizeButtonText(),
              callback = function() self:openSizeMenu() end },
            { id = "diff_button",   text = self:getDiffButtonText(),
              callback = function() self:openDifficultyMenu() end },
            { text = _("Undo"),     callback = function() self:onUndo() end },
            self:makeCloseButtonConfig(),
        }},
    }
    self.size_button = top_buttons:getButtonById("size_button")
    self.diff_button = top_buttons:getButtonById("diff_button")

    -- Digit buttons 1-MAX_ROOM
    local max_room = RippleEffectBoard.MAX_ROOM
    local digit_row = {}
    for d = 1, max_room do
        local dv = d
        digit_row[#digit_row + 1] = {
            text     = tostring(dv),
            callback = function() self:onDigitKey(dv) end,
        }
    end
    local digit_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = button_width,
        buttons = { digit_row },
    }

    local bottom_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = button_width,
        buttons = {{
            { text = _("Erase"),  callback = function() self:onErase() end },
            { text = _("Check"),  callback = function() self:onCheck() end },
            { text = _("Reveal"), callback = function() self:onReveal() end },
        }},
    }

    if is_landscape then
        local right_panel = VerticalGroup:new{
            align = "center",
            top_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
            VerticalSpan:new{ width = Size.span.vertical_large },
            digit_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            bottom_buttons,
        }
        self.layout = HorizontalGroup:new{
            align  = "center",
            board_frame,
            HorizontalSpan:new{ width = Size.span.horizontal_default },
            right_panel,
        }
    else
        self.layout = VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = Size.span.vertical_large },
            top_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            board_frame,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
            VerticalSpan:new{ width = Size.span.vertical_large },
            digit_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            bottom_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
        }
    end
    self[1] = self.layout
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
        title     = _("Select grid size"),
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
        status = T(_("%1\xC3\x97%2 \xC2\xB7 %3 \xC2\xB7 Empty: %4"), n, n, label, empty)
    end
    ScreenBase.updateStatus(self, status)
end

function RippleEffectScreen:getSizeButtonText()
    local n = self.board.n
    return T(_("Size: %1"), n .. "\xC3\x97" .. n)
end

function RippleEffectScreen:getDiffButtonText()
    local diff  = self.plugin:getSetting("difficulty", "easy")
    local label = MenuHelper.DIFFICULTY_LABELS[diff] or diff
    return T(_("Diff: %1"), label)
end

return RippleEffectScreen
