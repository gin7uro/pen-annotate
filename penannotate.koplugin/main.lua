--[[--
Freehand pen annotation plugin for KOReader.

Lets you draw ink annotations on top of document pages using an active
stylus (EMR/Wacom-style pens -- e.g. the Supernote pen on a Nomad or Manta).

It relies on KOReader's `Device.input:registerStylusCallback()` API, which
reports raw contacts *already tagged by tool type* (finger / pen / eraser /
highlighter) before they reach the normal gesture detector. On KOReader
builds that don't ship that API yet, lib/input_stylus_hook.lua polyfills
the same behavior in pure Lua. Because of that:

* Only actual stylus contacts ever reach this plugin's drawing code.
* Finger touches are never intercepted here, so page turning, menus and
  every other finger gesture keep working exactly as before, even while
  "Draw with pen" is enabled.
* If the pen has side buttons wired up as an eraser/highlighter selector,
  switching tool with the button switches mode here too.
* For pens without side buttons (e.g. the Supernote pen), the current
  tool -- pen, highlighter or eraser -- can instead be picked manually
  from the menu, or bound to a gesture/button via the Dispatcher.
* On Supernote devices, lib/supernote_ink.lua drives the firmware's own
  low-latency ink renderer while drawing, instead of waiting on KOReader's
  normal repaint; see the "Low-latency Supernote ink" menu toggle.

Limitations (by design, to keep this simple and reliable):
* Ink is stored in unscaled page-pixel coordinates, so it stays put across
  zoom/pan for fixed-layout documents (PDF, DjVu, CBZ, scanned books).
* For reflowable documents (EPUB/FB2/...), ink is anchored to the screen
  position at the time of drawing and may drift after you change fonts,
  margins or other layout settings.
* The eraser removes whole strokes that pass near the contact point,
  rather than erasing individual pixels.

@module koplugin.PenAnnotate
]]

local Device = require("device")

if not Device:isTouchDevice() then
    return { disabled = true }
end

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Math = require("optmath")
local logger = require("logger")
local StylusHook = require("lib/input_stylus_hook")
local SupernoteInk = require("lib/supernote_ink")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen
local Input = Device.input

-- Grayscale palette: works well on both B&W and color e-ink panels.
local PEN_COLORS = {
    { _("Black"),      Blitbuffer.COLOR_BLACK },
    { _("Dark gray"),  Blitbuffer.COLOR_GRAY_4 },
    { _("Gray"),       Blitbuffer.COLOR_GRAY },
}
local COLOR_BY_NAME = {}
for _, c in ipairs(PEN_COLORS) do COLOR_BY_NAME[c[1]] = c[2] end

local PenAnnotate = WidgetContainer:extend{
    name = "penannotate",
    is_doc_only = true,
}

function PenAnnotate:init()
    -- Native on recent KOReader builds; polyfilled in pure Lua otherwise (see
    -- lib/input_stylus_hook.lua), so "Draw with pen" isn't needlessly grayed
    -- out on official releases that predate the native API.
    StylusHook.install(Input)
    self.stylus_api_available = type(Input.registerStylusCallback) == "function"
    -- Diagnostic: check KOReader's debug log if pen strokes aren't registering.
    -- "stylus API available = false" means this KOReader build is too old (no
    -- Input:registerStylusCallback at all). If it's true but no "onStylusSlot"
    -- lines ever show up while actively drawing with the pen, the platform
    -- layer isn't tagging the Supernote pen's contacts as a stylus tool at all.
    logger.info("PenAnnotate: stylus API available =", self.stylus_api_available)
    self.draw_mode = false
    self.pen_color_name = G_reader_settings:readSetting("penannotate_color") or PEN_COLORS[1][1]
    self.pen_width = G_reader_settings:readSetting("penannotate_width") or Screen:scaleBySize(3)
    self.highlighter_width = G_reader_settings:readSetting("penannotate_highlighter_width") or Screen:scaleBySize(10)
    self.eraser_width = G_reader_settings:readSetting("penannotate_eraser_width") or Screen:scaleBySize(12)
    -- Manually selected tool, used when the pen hardware doesn't report one (e.g. no side buttons).
    self.tool_mode = G_reader_settings:readSetting("penannotate_tool_mode") or "pen"
    -- Low-latency firmware ink on Supernote devices; a no-op everywhere else.
    -- Kept behind a setting since it drives an undocumented, reverse-engineered
    -- binder API -- users can turn it off if a firmware update misbehaves.
    self.supernote_ink_enabled = G_reader_settings:nilOrTrue("penannotate_supernote_ink_enabled")
    self.supernote_ink_active = false
    self.supernote_last_tool = nil
    self.strokes = {} -- [pageno] = { stroke, stroke, ... }, filled in onReadSettings
    self.current_stroke = nil
    self.current_page = nil

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function PenAnnotate:onDispatcherRegisterActions()
    Dispatcher:registerAction("penannotate_toggle_draw_mode", {
        category = "none",
        event = "PenAnnotateToggleDrawMode",
        title = _("Pen annotate: toggle draw mode"),
        reader = true,
    })
    Dispatcher:registerAction("penannotate_tool_pen", {
        category = "none",
        event = "PenAnnotateSetToolPen",
        title = _("Pen annotate: switch to pen"),
        reader = true,
    })
    Dispatcher:registerAction("penannotate_tool_highlighter", {
        category = "none",
        event = "PenAnnotateSetToolHighlighter",
        title = _("Pen annotate: switch to highlighter"),
        reader = true,
    })
    Dispatcher:registerAction("penannotate_tool_eraser", {
        category = "none",
        event = "PenAnnotateSetToolEraser",
        title = _("Pen annotate: switch to eraser"),
        reader = true,
    })
    Dispatcher:registerAction("penannotate_show_tool_picker", {
        category = "none",
        event = "PenAnnotateShowToolPicker",
        title = _("Pen annotate: show tool picker"),
        reader = true,
    })
    Dispatcher:registerAction("penannotate_undo_last_stroke", {
        category = "none",
        event = "PenAnnotateUndoLastStroke",
        title = _("Pen annotate: undo last stroke"),
        reader = true,
    })
end

function PenAnnotate:onReaderReady()
    self.view:registerViewModule("penannotate", self)
    if self.stylus_api_available then
        Input:registerStylusCallback(function(_, slot) return self:onStylusSlot(slot) end)
    end
end

function PenAnnotate:onCloseDocument()
    self:_finishStroke()
    if self.stylus_api_available then
        Input:unregisterStylusCallback()
    end
    if self.draw_mode then
        self.draw_mode = false
    end
    self:_releaseSupernoteInk()
end
PenAnnotate.onCloseWidget = PenAnnotate.onCloseDocument

-- Release firmware ink ownership across a device sleep so a foregrounded
-- app (e.g. the launcher) doesn't keep painting under finger taps using our
-- last-pushed pen config; resume re-claims it if drawing is still enabled.
function PenAnnotate:onSuspend()
    if not self.supernote_ink_active then return end
    SupernoteInk.clearAll()
    SupernoteInk.enableFullUiAuto(false)
end

function PenAnnotate:onResume()
    if not self.supernote_ink_active then return end
    SupernoteInk.sendWriteAppInfo()
    SupernoteInk.enableFullUiAuto(true)
    SupernoteInk.clearDisableAreas()
    self.supernote_last_tool = nil -- force applyPen() to re-push below
    self:_applySupernotePen()
end

function PenAnnotate:onReadSettings(config)
    self.strokes = config:readSetting("pen_annotations") or {}
end

function PenAnnotate:onSaveSettings()
    self.ui.doc_settings:saveSetting("pen_annotations", self.strokes)
end

-- Draw mode ------------------------------------------------------------

function PenAnnotate:setDrawMode(enabled, silent)
    if enabled and not self.stylus_api_available then
        UIManager:show(InfoMessage:new{
            text = _("Your KOReader build does not expose the stylus input API needed for pen annotations.\nPlease update KOReader."),
        })
        return
    end
    if self.draw_mode == enabled then return end
    self:_finishStroke()
    self.draw_mode = enabled
    if enabled then
        self:_claimSupernoteInk()
    else
        self:_releaseSupernoteInk()
    end
    if not silent then
        Notification:notify(enabled and _("Pen drawing: ON") or _("Pen drawing: OFF"))
    end
end

function PenAnnotate:onPenAnnotateToggleDrawMode()
    self:setDrawMode(not self.draw_mode)
    return true
end

-- Manual tool selection ---------------------------------------------------

function PenAnnotate:setToolMode(mode, silent)
    if self.tool_mode == mode then return end
    self:_finishStroke()
    self.tool_mode = mode
    G_reader_settings:saveSetting("penannotate_tool_mode", mode)
    self:_applySupernotePen()
    if not silent then
        local names = { pen = _("Pen"), highlighter = _("Highlighter"), eraser = _("Eraser") }
        Notification:notify(T(_("Pen annotate tool: %1"), names[mode]))
    end
end

function PenAnnotate:onPenAnnotateSetToolPen()
    self:setToolMode("pen")
    return true
end

function PenAnnotate:onPenAnnotateSetToolHighlighter()
    self:setToolMode("highlighter")
    return true
end

function PenAnnotate:onPenAnnotateSetToolEraser()
    self:setToolMode("eraser")
    return true
end

-- Quick tool picker, meant to be bound to a gesture so it doesn't require
-- digging through the main menu (e.g. for pens with no side buttons).
function PenAnnotate:showToolPicker()
    local dialog
    local function toolButton(mode, text)
        return {
            text = (self.tool_mode == mode and "● " or "○ ") .. text,
            callback = function()
                self:setToolMode(mode)
                UIManager:close(dialog)
            end,
        }
    end
    dialog = ButtonDialog:new{
        title = _("Pen annotate tool"),
        title_align = "center",
        buttons = {
            { toolButton("pen", _("Pen")) },
            { toolButton("highlighter", _("Highlighter")) },
            { toolButton("eraser", _("Eraser")) },
            {
                {
                    text = self.draw_mode and _("Drawing: ON (tap to disable)") or _("Drawing: OFF (tap to enable)"),
                    callback = function()
                        self:setDrawMode(not self.draw_mode, true)
                        UIManager:close(dialog)
                    end,
                },
            },
            {
                {
                    text = _("Undo last stroke"),
                    callback = function()
                        self:undoLastStroke()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Clear this page"),
                    callback = function()
                        self:clearPageStrokes()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function PenAnnotate:onPenAnnotateShowToolPicker()
    self:showToolPicker()
    return true
end

-- Undo -------------------------------------------------------------------

function PenAnnotate:undoLastStroke()
    local page = self.ui:getCurrentPage()
    local page_strokes = self.strokes[page]
    if not page_strokes or #page_strokes == 0 then
        Notification:notify(_("Nothing to undo on this page"))
        return
    end
    table.remove(page_strokes)
    if #page_strokes == 0 then self.strokes[page] = nil end
    self.updated = true
    UIManager:setDirty(self.dialog, "ui")
    Notification:notify(_("Undid last pen stroke"))
end

function PenAnnotate:onPenAnnotateUndoLastStroke()
    self:undoLastStroke()
    return true
end

function PenAnnotate:clearPageStrokes()
    local page = self.ui:getCurrentPage()
    if not self.strokes[page] then
        Notification:notify(_("Nothing to clear on this page"))
        return
    end
    self.strokes[page] = nil
    self.updated = true
    UIManager:setDirty(self.dialog, "ui")
    Notification:notify(_("Cleared this page"))
end

-- Supernote firmware ink ---------------------------------------------------
-- A no-op everywhere except Supernote devices with the ink binder present
-- (see lib/supernote_ink.lua). Claims the firmware's low-latency ink
-- overlay while drawing is on, so pen strokes appear with no visible lag,
-- and releases it the rest of the time so it doesn't paint under fingers.

local SUPERNOTE_COLOR_BY_NAME = {
    [_("Black")] = SupernoteInk.Color.BLACK,
    [_("Dark gray")] = SupernoteInk.Color.DARK_GRAY,
    [_("Gray")] = SupernoteInk.Color.GRAY,
}

-- KOReader stroke widths are plain screen pixels; the firmware wants its
-- own EMR pressure/size unit. There's no exact mapping, just a usable range.
local function widthToSupernoteEmr(width)
    local emr = math.floor((width or 3) * 100)
    if emr < 200 then emr = 200 end
    if emr > 2400 then emr = 2400 end
    return emr
end

function PenAnnotate:_claimSupernoteInk()
    if self.supernote_ink_active or not self.supernote_ink_enabled then return end
    if not SupernoteInk.isAvailable() then return end
    SupernoteInk.sendWriteAppInfo()
    SupernoteInk.enableFullUiAuto(true)
    SupernoteInk.clearDisableAreas()
    self.supernote_ink_active = true
    self.supernote_last_tool = nil -- force _applySupernotePen() to push below
    self:_applySupernotePen()
end

function PenAnnotate:_releaseSupernoteInk()
    if not self.supernote_ink_active then return end
    SupernoteInk.setFullScreenDisable(Screen:getWidth(), Screen:getHeight())
    SupernoteInk.clearAll()
    SupernoteInk.enableFullUiAuto(false)
    self.supernote_ink_active = false
    self.supernote_last_tool = nil
end

-- Push the current tool (pen/highlighter/eraser) down to the firmware.
-- `tool` is an Input.TOOL_TYPE_* constant for a live stylus event, or nil to
-- derive it from the manually selected self.tool_mode (e.g. on menu changes).
function PenAnnotate:_applySupernotePen(tool)
    if not self.supernote_ink_active then return end
    local effective = tool or self:_effectiveTool(Input.TOOL_TYPE_PEN)
    if effective == self.supernote_last_tool then return end
    self.supernote_last_tool = effective
    if effective == Input.TOOL_TYPE_ERASER then
        SupernoteInk.setEraser(false, math.max(400, self.eraser_width * 50))
    else
        local is_highlighter = effective == Input.TOOL_TYPE_HIGHLIGHTER
        local width = is_highlighter and self.highlighter_width or self.pen_width
        local pen_type = is_highlighter and SupernoteInk.Pen.MARK or SupernoteInk.Pen.NEEDLE
        local color = SUPERNOTE_COLOR_BY_NAME[self.pen_color_name] or SupernoteInk.Color.BLACK
        SupernoteInk.setPen(pen_type, widthToSupernoteEmr(width), color)
    end
end

-- Stylus event handling --------------------------------------------------

-- Called by Device.input for every contact tagged as a stylus (pen/eraser/
-- highlighter tool), before it reaches the normal gesture detector.
-- Returning true "dominates" the event, removing it from gesture detection.
function PenAnnotate:onStylusSlot(slot)
    -- Logged unconditionally (even when draw mode is off) so it also shows
    -- whether the platform ever routes the pen here at all, cf. init().
    logger.dbg("PenAnnotate: onStylusSlot tool=", slot.tool, "id=", slot.id,
        "x=", slot.x, "y=", slot.y)

    if not self.draw_mode then
        return false -- let it fall through, e.g. pen taps still turn pages
    end

    if slot.id == -1 then
        self:_finishStroke()
        return true
    end

    -- Undo the same rotation adjustment GestureDetector applies to touch
    -- input, since we receive raw, pre-rotation coordinates here.
    local ges = { pos = Geom:new{ x = slot.x, y = slot.y, w = 0, h = 0 } }
    Input.gesture_detector:adjustGesCoordinate(ges)
    local pos = ges.pos

    local tool = self:_effectiveTool(slot.tool)
    self:_applySupernotePen(tool)
    if tool == Input.TOOL_TYPE_ERASER then
        self:_finishStroke()
        self:_eraseNear(pos.x, pos.y)
        return true
    end

    self:_extendStroke(pos.x, pos.y, tool)
    return true
end

-- Hardware-reported eraser/highlighter tools win (pens with side buttons);
-- otherwise fall back to the manually selected tool mode, for pens (like
-- the Supernote pen) that always report a plain, generic contact.
function PenAnnotate:_effectiveTool(hw_tool)
    if hw_tool == Input.TOOL_TYPE_ERASER or hw_tool == Input.TOOL_TYPE_HIGHLIGHTER then
        return hw_tool
    end
    if self.tool_mode == "highlighter" then return Input.TOOL_TYPE_HIGHLIGHTER end
    if self.tool_mode == "eraser" then return Input.TOOL_TYPE_ERASER end
    return hw_tool
end

function PenAnnotate:_extendStroke(x, y, tool)
    local page = self.ui:getCurrentPage()
    local is_highlighter = tool == Input.TOOL_TYPE_HIGHLIGHTER
    local width = is_highlighter and self.highlighter_width or self.pen_width
    if not self.current_stroke or self.current_page ~= page then
        self:_finishStroke()
        self.current_page = page
        self.current_stroke = {
            color_name = self.pen_color_name,
            width = width,
            highlighter = is_highlighter,
            pts = {},
        }
    end

    local page_pos = self.view:screenToPageTransform(Geom:new{ x = x, y = y, w = 0, h = 0 })
    if not page_pos then return end

    local pts = self.current_stroke.pts
    table.insert(pts, { x = page_pos.x, y = page_pos.y })

    -- While the firmware overlay is active it already shows live ink at far
    -- lower latency than we could; a Lua-side repaint here would just race
    -- it and visibly flicker the stroke, so skip it and let _finishStroke's
    -- final "ui" repaint (plus the delayed overlay clear) take over instead.
    if not self.supernote_ink_active then
        local rect = self:_screenBoundingRect(page, pts[#pts - 1], pts[#pts])
        if rect then
            UIManager:setDirty(self.dialog, function() return "fast", rect end)
        end
    end
end

function PenAnnotate:_finishStroke()
    if not self.current_stroke then return end
    if #self.current_stroke.pts > 0 then
        self.strokes[self.current_page] = self.strokes[self.current_page] or {}
        table.insert(self.strokes[self.current_page], self.current_stroke)
        self.updated = true
        UIManager:setDirty(self.dialog, "ui")
        if self.supernote_ink_active then
            -- Give the "ui" repaint above time to actually reach the panel
            -- before wiping the overlay, or the stroke would flash off screen.
            UIManager:scheduleIn(0.3, SupernoteInk.clearAll)
        end
    end
    self.current_stroke = nil
end

function PenAnnotate:_eraseNear(x, y)
    local page = self.ui:getCurrentPage()
    local page_pos = self.view:screenToPageTransform(Geom:new{ x = x, y = y, w = 0, h = 0 })
    if not page_pos then return end
    local page_strokes = self.strokes[page]
    if not page_strokes then return end

    local radius = self.eraser_width
    local removed = false
    for i = #page_strokes, 1, -1 do
        local stroke = page_strokes[i]
        for _, pt in ipairs(stroke.pts) do
            local dx, dy = pt.x - page_pos.x, pt.y - page_pos.y
            if (dx * dx + dy * dy) <= radius * radius then
                table.remove(page_strokes, i)
                removed = true
                break
            end
        end
    end
    if removed then
        if #page_strokes == 0 then
            self.strokes[page] = nil
        end
        self.updated = true
        UIManager:setDirty(self.dialog, "ui")
    end
end

-- Rendering --------------------------------------------------------------

function PenAnnotate:_getStrokeColor(stroke)
    if stroke.highlighter then
        return Blitbuffer.COLOR_GRAY
    end
    return COLOR_BY_NAME[stroke.color_name] or Blitbuffer.COLOR_BLACK
end

function PenAnnotate:_paintDot(bb, cx, cy, width, color)
    local half = math.floor(width / 2)
    bb:paintRect(Math.round(cx - half), Math.round(cy - half), width, width, color)
end

function PenAnnotate:_paintThickLine(bb, x0, y0, x1, y1, width, color)
    local dx, dy = x1 - x0, y1 - y0
    local dist = math.sqrt(dx * dx + dy * dy)
    local step = math.max(1, width * 0.5)
    local steps = math.max(1, Math.round(dist / step))
    for i = 0, steps do
        local t = i / steps
        self:_paintDot(bb, x0 + dx * t, y0 + dy * t, width, color)
    end
end

function PenAnnotate:_paintStroke(bb, x, y, page, stroke)
    local pts = stroke.pts
    if #pts == 0 then return end
    local color = self:_getStrokeColor(stroke)
    local prev_screen
    for i = 1, #pts do
        local r = self.view:pageToScreenTransform(page, Geom:new{ x = pts[i].x, y = pts[i].y, w = 0, h = 0 })
        if r then
            local sx, sy = x + r.x, y + r.y
            if prev_screen then
                self:_paintThickLine(bb, prev_screen.x, prev_screen.y, sx, sy, stroke.width, color)
            else
                self:_paintDot(bb, sx, sy, stroke.width, color)
            end
            prev_screen = { x = sx, y = sy }
        end
    end
end

function PenAnnotate:_screenBoundingRect(page, p0, p1)
    local pad = (self.current_stroke and self.current_stroke.width or self.pen_width) + 2
    local function toScreen(p)
        return self.view:pageToScreenTransform(page, Geom:new{ x = p.x, y = p.y, w = 0, h = 0 })
    end
    local s1 = toScreen(p1)
    if not s1 then return nil end
    local s0 = p0 and toScreen(p0) or s1
    if not s0 then s0 = s1 end
    local x0, x1 = math.min(s0.x, s1.x), math.max(s0.x, s1.x)
    local y0, y1 = math.min(s0.y, s1.y), math.max(s0.y, s1.y)
    return Geom:new{
        x = x0 - pad, y = y0 - pad,
        w = x1 - x0 + pad * 2, h = y1 - y0 + pad * 2,
    }
end

-- Called by ReaderView for every repaint, as a registered view module.
function PenAnnotate:paintTo(bb, x, y)
    if next(self.strokes) == nil and not self.current_stroke then return end

    local pages
    if self.ui.paging then
        pages = self.view:getCurrentPageList()
    else
        pages = { self.ui:getCurrentPage() }
    end

    for _, page in ipairs(pages) do
        local page_strokes = self.strokes[page]
        if page_strokes then
            for _, stroke in ipairs(page_strokes) do
                self:_paintStroke(bb, x, y, page, stroke)
            end
        end
    end

    if self.current_stroke and self.current_page then
        self:_paintStroke(bb, x, y, self.current_page, self.current_stroke)
    end
end

-- Menu ---------------------------------------------------------------------

local TOOL_MODES = {
    { "pen",         _("Pen") },
    { "highlighter", _("Highlighter") },
    { "eraser",      _("Eraser") },
}
local TOOL_MODE_NAME = {}
for _, t in ipairs(TOOL_MODES) do TOOL_MODE_NAME[t[1]] = t[2] end

function PenAnnotate:_genColorMenu()
    local items = {}
    for _, c in ipairs(PEN_COLORS) do
        table.insert(items, {
            text = c[1],
            radio = true,
            checked_func = function() return self.pen_color_name == c[1] end,
            callback = function()
                self.pen_color_name = c[1]
                G_reader_settings:saveSetting("penannotate_color", c[1])
                self.supernote_last_tool = nil -- color changed, not tool; force a re-push
                self:_applySupernotePen()
            end,
        })
    end
    return items
end

function PenAnnotate:_genToolMenu()
    local items = {}
    for _, t in ipairs(TOOL_MODES) do
        table.insert(items, {
            text = t[2],
            radio = true,
            checked_func = function() return self.tool_mode == t[1] end,
            callback = function() self:setToolMode(t[1]) end,
        })
    end
    return items
end

function PenAnnotate:_showWidthPicker(title, value, setting_name, apply)
    UIManager:show(SpinWidget:new{
        title_text = title,
        value = value,
        value_min = 1,
        value_max = Screen:scaleBySize(30),
        value_step = 1,
        value_hold_step = 2,
        ok_text = _("Set"),
        callback = function(spin)
            apply(spin.value)
            G_reader_settings:saveSetting(setting_name, spin.value)
            self.supernote_last_tool = nil -- width changed, not tool; force a re-push
            self:_applySupernotePen()
        end,
    })
end

function PenAnnotate:addToMainMenu(menu_items)
    menu_items.penannotate = {
        text = _("Pen annotations"),
        sub_item_table = {
            {
                text = _("Draw with pen"),
                checked_func = function() return self.draw_mode end,
                enabled_func = function() return self.stylus_api_available end,
                callback = function() self:setDrawMode(not self.draw_mode) end,
            },
            {
                text = _("Low-latency Supernote ink (experimental)"),
                help_text = _("Uses the Supernote firmware's own ink renderer for near-instant stylus feedback. Has no effect on non-Supernote devices. Turn off if strokes look wrong or the firmware misbehaves."),
                checked_func = function() return self.supernote_ink_enabled end,
                enabled_func = function() return SupernoteInk.isAvailable() end,
                callback = function()
                    self.supernote_ink_enabled = not self.supernote_ink_enabled
                    G_reader_settings:saveSetting("penannotate_supernote_ink_enabled", self.supernote_ink_enabled)
                    if self.supernote_ink_enabled and self.draw_mode then
                        self:_claimSupernoteInk()
                    else
                        self:_releaseSupernoteInk()
                    end
                end,
            },
            {
                text_func = function()
                    return T(_("Tool: %1"), TOOL_MODE_NAME[self.tool_mode])
                end,
                sub_item_table_func = function() return self:_genToolMenu() end,
            },
            {
                text = _("Show tool picker popup"),
                keep_menu_open = true,
                callback = function() self:showToolPicker() end,
                separator = true,
            },
            {
                text_func = function()
                    return T(_("Pen color: %1"), self.pen_color_name)
                end,
                sub_item_table_func = function() return self:_genColorMenu() end,
            },
            {
                text = _("Pen width"),
                keep_menu_open = true,
                callback = function()
                    self:_showWidthPicker(_("Pen width"), self.pen_width, "penannotate_width",
                        function(v) self.pen_width = v end)
                end,
            },
            {
                text = _("Highlighter width"),
                keep_menu_open = true,
                callback = function()
                    self:_showWidthPicker(_("Highlighter width"), self.highlighter_width, "penannotate_highlighter_width",
                        function(v) self.highlighter_width = v end)
                end,
            },
            {
                text = _("Eraser size"),
                keep_menu_open = true,
                callback = function()
                    self:_showWidthPicker(_("Eraser size"), self.eraser_width, "penannotate_eraser_width",
                        function(v) self.eraser_width = v end)
                end,
                separator = true,
            },
            {
                text = _("Undo last stroke on this page"),
                enabled_func = function()
                    local page_strokes = self.strokes[self.ui:getCurrentPage()]
                    return page_strokes and #page_strokes > 0
                end,
                callback = function() self:undoLastStroke() end,
            },
            {
                text = _("Clear this page"),
                enabled_func = function()
                    local page_strokes = self.strokes[self.ui:getCurrentPage()]
                    return page_strokes and #page_strokes > 0
                end,
                callback = function() self:clearPageStrokes() end,
            },
            {
                text = _("Clear all pen annotations in this book"),
                separator = true,
                enabled_func = function() return next(self.strokes) ~= nil end,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Remove all pen annotations from this book? This cannot be undone."),
                        ok_text = _("Remove"),
                        ok_callback = function()
                            self.strokes = {}
                            self.updated = true
                            UIManager:setDirty(self.dialog, "ui")
                        end,
                    })
                end,
            },
            {
                text = _("About pen annotations"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _([[Draw freehand ink annotations using an active stylus (e.g. the Supernote pen on a Nomad or Manta).

1. Enable "Draw with pen" above (or assign it to a gesture/button in "More tools" > "Taps and gestures" > "Dispatcher").
2. Draw on the page with your stylus. Finger touches still turn pages and open menus normally.
3. Pick the active tool -- Pen, Highlighter or Eraser -- from "Tool" above, or tap "Show tool picker popup" for a quick dialog. If your pen has a side button wired as an eraser/highlighter, that overrides the selection while held. Pens without buttons (e.g. Supernote) can bind the popup, or each tool directly, to a gesture via the Dispatcher ("Pen annotate: show tool picker" / "switch to pen/highlighter/eraser").

On Supernote devices, "Low-latency Supernote ink" (on by default) draws strokes with the firmware's own renderer for near-instant feedback, instead of waiting on KOReader's normal repaint.

Ink is saved per page, positioned correctly for fixed-layout documents (PDF, DjVu, CBZ). On reflowable EPUBs, ink is anchored to the screen position at drawing time and may not stay put across font or layout changes.

If nothing appears when you draw, your device may not be reporting the pen as a distinct input tool to KOReader; "Draw with pen" being grayed out confirms this.]]),
                    })
                end,
            },
        },
    }
end

return PenAnnotate
