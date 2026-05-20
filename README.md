# Bonsai

A Windower 4 addon that automates daily tasks in the Mog Garden, such as harvesting, monster rearing pets, and furrows.

## Install

Drop the `Bonsai` folder into your Windower addons directory and then load it ingame with `lua l Bonsai`.

## Commands

To operate Bonsai, use the command `//bonsai` (or `//bon` for short).

### Garden
- `//bon garden` runs all 4 garden nodes in order: Mineral Vein, Pond Dredger, Arboreal Grove, Coastal Fishing Net.
- `//bon mine`, `//bon dredger`, `//bon grove`, `//bon net`, `//bon flotsam` run a single garden node.

### Furrows
- `//bon furrow start [1|2] [fert]` begins the Furrow loop: plant a Revival Root in each Garden Furrow, wait for them to grow, harvest, repeat.
  - `1` (default) = plant first, `2` = harvest first
  - `fert` = use Miracle Mulch after planting (reduces wait from 61 min to 30 min)
  - Examples: `//bon furrow start`, `//bon furrow start fert`, `//bon furrow start 2 fert`
- `//bon furrow stop` stops the Furrow loop.
- `//bon furrow status` shows how long until the planted furrows are ready, or what the loop is currently doing.
- `//bon fert` toggles Miracle Mulch fertilizing on/off (default: OFF). When enabled, the loop becomes: plant -> fertilize -> wait 30 min -> harvest -> repeat.

### Monster Rearing
- `//bon pet` pets every breeding monster in the rearing grounds. Please use this only in the Rearing Grounds part of the Mog Garden. If used in the main Mog Garden area, it will cancel.

### Full Automation
- `//bon all` runs your customizable node order, then (if `pet` is included) warps to the rearing grounds via Chacharoon and pets all monsters. The default order is Mineral Vein, Pond Dredger, Arboreal Grove, Flotsam, Coastal Fishing Net, then pet.
- `//bon add <node>` / `//bon remove <node>` add or remove a node from your `//bon all` order. Valid nodes: `mine`, `dredger`, `grove`, `net`, `flotsam`, `pet`. The order is saved per character.
- `//bon list` shows your current `//bon all` order.
- `//bon cancel` aborts the current run.

## Requirements

- The garden, furrow, and `all` commands require you to be in Mog Garden.
- `//bon pet` should be ran only when you are in the Rearing Grounds part of your Mog Garden.
- `//bon all` should be ran from the main Mog Garden area and will naturally transition to the Rearing Grounds after completing the garden tasks.

### Furrow Requirements
Furrow uses Revival Roots (https://www.bg-wiki.com/ffxi/Revival_Root) specifically for planting. This means each plant cycle will be 1 hour long. 

As such, you need at least one Revival Root in your inventory for it to work. The loop will keep planting and harvesting until you run out.

## Notes

The addon walks your character to each NPC directly, so be sure to have a clear straight path between nodes when running it. The natural order defined by the addon will always have a clear pathing and should not get stuck.

In `//bon all`, `pet` always runs last regardless of where it sits in your order, since the warp to the Rearing Grounds is one-way.

## Known Bugs

When using `//bon all` and moving to the Rearing Grounds, due to the nature of the packet teleport sequence, it's possible that ghost monsters may spawn if you don't have the full 4 monster breeding slots filled. In such scenarios, the addon will skip over those monsters automatically. So far it seems to only be a visual glitch.

When using `//bon all` and moving to the Rearing Grounds, all rearing monsters will appear as the default mob model (Sheep). This seems to just be an aesthetic glitch and is fixed upon zoning.
