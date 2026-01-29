data:extend({
  { type = "int-setting", name = "sbt-contract-duration-min", setting_type = "runtime-global", default_value = 10, minimum_value = 2, maximum_value = 120 },
  { type = "bool-setting", name = "sbt-hostile-waves", setting_type = "runtime-global", default_value = false },
  {
    type = "int-setting",
    name = "ftt-offer-generosity",
    setting_type = "runtime-global",
    default_value = 3,
    minimum_value = 1,
    maximum_value = 10,
    order = "c[offers]-a[generosity]"
  }
})
