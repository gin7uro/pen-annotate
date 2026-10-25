--[[--
Runtime polyfill for `Device.input:registerStylusCallback()`.

Recent KOReader builds implement stylus routing natively in
`frontend/device/input.lua` (registerStylusCallback / routeStylusEvents),
but older official releases don't have it yet. Rather than refuse to work
on those builds, this module reproduces the same behavior purely in Lua:
it wraps `gesture_detector:feedEvent()` (the single choke point every
`handleTouchEv*` variant funnels into) so stylus-tagged slots are pulled
out of the touch-slot list -- and handed to our callback -- before gesture
detection ever sees them.

Safe to call unconditionally: if the native API is already present, this
is a no-op and the native implementation is used instead.

Known gap: promoting a pen's side button to eraser/highlighter tool is
done deep inside the platform's touch translation layer (e.g. reading
Android MotionEvent button state in koreader-base), which this plugin
can't reach. On builds without the native API, a plain pen contact always
reports as TOOL_TYPE_PEN regardless of any side button; use the plugin's
manual tool picker instead.
--]]

local logger = require("logger")

local TOOL_TYPE_PEN = 1
local TOOL_TYPE_ERASER = 2
local TOOL_TYPE_HIGHLIGHTER = 3

local M = {}

function M.install(Input)
    if not Input then return false end
    if Input.registerStylusCallback then return true end -- native API present
    if Input._penannotate_stylus_hook_installed then return true end

    function Input:registerStylusCallback(callback)
        self.stylus_callback = callback
        logger.info("PenAnnotate: polyfilled stylus callback registered")
    end

    function Input:unregisterStylusCallback()
        self.stylus_callback = nil
    end

    function Input:routeStylusEvents()
        if not self.stylus_callback or not self.MTSlots then return end
        local dominated = {}
        for i, slot in ipairs(self.MTSlots) do
            local is_stylus = slot.tool == TOOL_TYPE_PEN
                or slot.tool == TOOL_TYPE_ERASER
                or slot.tool == TOOL_TYPE_HIGHLIGHTER
                or (self.pen_slot and slot.slot == self.pen_slot)
            if is_stylus and self.stylus_callback(self, slot) then
                table.insert(dominated, i)
            end
        end
        for i = #dominated, 1, -1 do
            table.remove(self.MTSlots, dominated[i])
        end
    end

    local gesture_detector = Input.gesture_detector
    if not gesture_detector then
        logger.warn("PenAnnotate: gesture_detector not ready, stylus hook not installed")
        return false
    end
    if not gesture_detector._penannotate_feed_wrapped then
        local original_feed_event = gesture_detector.feedEvent
        gesture_detector.feedEvent = function(self, tev_list)
            Input:routeStylusEvents()
            return original_feed_event(self, tev_list)
        end
        gesture_detector._penannotate_feed_wrapped = true
    end

    Input._penannotate_stylus_hook_installed = true
    logger.info("PenAnnotate: stylus callback polyfill installed")
    return true
end

return M
