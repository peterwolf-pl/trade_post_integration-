
local function icon(path)
  return "__space-bug-trade__/graphics/icons/" .. path
end

data:extend({

  -- Cargo rover
  {
    type = "car",
    name = "sbt-cargo-rover",
    icon = icon("rover.png"),
    icon_size = 64,
    flags = {"placeable-neutral","player-creation"},
    minable = {mining_time = 0.5, result = "sbt-cargo-rover"},
    max_health = 600,
    inventory_size = 60,
    effectivity = 1.0,
    consumption = "150kW",
    braking_power = "300kW",
    weight = 400,
    rotation_speed = 0.015,
    energy_source = {type = "burner", fuel_category = "chemical", effectivity = 1, fuel_inventory_size = 2},
    animation = table.deepcopy(data.raw.car.car.animation)
  },

  -- Bug tradepost
  {
    type = "simple-entity-with-owner",
    name = "sbt-bug-tradepost",
    icon = icon("credit.png"),
    icon_size = 64,
    flags = {"placeable-neutral","player-creation"},
    minable = {mining_time = 0.5, result = "stone"},
    collision_box = {{-1.2, -1.0}, {1.2, 1.0}},
    selection_box = {{-1.2, -1.0}, {1.2, 1.0}},
    picture = {
      filename = "__space-bug-trade__/graphics/entity/bug_tradepost.png",
      width = 256,
      height = 256,
      scale = 0.5,
      shift = {0, 0.1}
    }
  },

  -- Contract board
  {
    type = "simple-entity-with-owner",
    name = "sbt-contract-board",
    icon = icon("credit.png"),
    icon_size = 64,
    flags = {"placeable-neutral","player-creation"},
    collision_box = {{-0.7, -0.5}, {0.7, 0.5}},
    selection_box = {{-0.7, -0.5}, {0.7, 0.5}},
    picture = {
      filename = "__space-bug-trade__/graphics/entity/contract_board.png",
      width = 256,
      height = 256,
      scale = 0.5,
      shift = {0, 0}
    },
    -- mapa
    map_color = {r = 0.55, g = 0.43, b = 0.25},
    map_grid = false,
    tags = {"contract","trade"}
  }

})
