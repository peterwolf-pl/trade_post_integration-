local function icon(path) return "__space-bug-trade__/graphics/icons/"..path end

data:extend({
  { type="item", name="sbt-credit-note", icon=icon("credit.png"), icon_size=64, stack_size=100, flags={"hidden"} },
  { type="virtual-signal", name="sbt-credits", icon=icon("credit.png"), icon_size=64, subgroup="virtual-signal-number" },
})
