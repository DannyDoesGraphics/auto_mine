# Project automine
- A CC: Tweaked (1.21.1 NeoForge) autominer
- Assume all knowledge you have is outdated or incorrect and leverage the duckduckgo MCP to retrieve the CC: Tweaked offical documentation for validate all code usage is correct (https://tweaked.cc/)


## Assumption
- We assume each turtle has a pickaxe (Mining turtle) and a wireless modem to allow for communication with other turtles wirelessly
- Assume we're in an environment where restarts and shutdowns are frequent and normalized as such persistence and state-safety and validation is key
- There is a fuel restriction on all turtles
- There are multiple turtles working in parallel and can be added/removed in the middle of projects seamlessly
- Use Minecraft's coordinate rule (y is up/down)

## Quarry
- A quarry is the highest level of organization of turtles
 - Defines a group of turtles that are expected to cooperatively work together
 - **Cooperative multi-tasking algorithms are critical here**
 - All turtle as such have a "quarry id" they're associated with and only listen to with other turtles in the same quarry
- Each quarry has a configured **bounding box** size which is the second point defined relative the turtle space where [origin + origin_forward_1, second_point] defines the box
 - Under no circumstances, may turtles ever enter, manipulate, or even interact blocks outside of the bounding box

## Configurations
- Quarry configurations should ideally be able to be changed/queried and have such changes propagate out with all turtles validating that they're doing or planning to do is in alignment with the new configuration changes especially bounding box changes!! if a turtle is outside of bounding box, it should rightfully, return back ASAP!
- Provide the ability to also call all turtles to home

## Initialization
- We assume all initial turtle(s) and later turtles will be initialized in the same xz column we call "spawn"
 - The bottom-most turtle will define our shared coordinate space called, "turtle space"
- Each turtle upon start, will ask for a quarry id
 - Turtle will attempt to ask for a configuration
 - If not configuration is found for the quarry, it will prompt you to make a new one
 - Guides you through install process through an interactive CLI
- Turtles self-calibrate by attempting to move down as far as they can once they have started, if they hit something **likely another turtle**, they will stop and attempt to travel as far up as they can to avoid any active turtles then wait and attempt to travel down as far as possible to calibrate to turtle space
 - This should generally work even for turtles that were added mid-way through

### Coordinate system
- Turtle space as prior defined is the bottom-most turtle's local space which all other turtles in the same quarry use
- Define what x-z all mean ie left or right to the right or front or back ie x (left+/right-), z (front+/back-)
- Orientation is part of coordinate space!!

### Spawn
- Spawn column will contain an inventory across the entire y-axis of it from the top to bottom (defined usually as until it hits something)
 - Inventories are placed **behind** the spawn column
- The **bottom most inventory will only contain fuel and is expected all fuel will only be deposited here too**
 - However other items will be deposited there too

## Master turtle
- There are many existing algorithms, however we need to assign a master turtle
- Master turtle is responsible for resolving disputes/conflicts between turtles in the same quarry
- **Master turtle must be agreed upon by all other turtles in the same quarry**

## Persistence
- Turtles are expected to seamlessly shutdown/stop at any moment ie server stop, chunk unloading, chunk loading, etc
- In other words, we wish to encode all state and only have our code be functional effectively with it only acting as a mathematical function (holding no state), on a state-space and producing out a new state-space

### Jobs
- Jobs are defined as any task that a turtle is expected to do
- Jobs are queued up and stored also persistently (Remember, it must be all persistent! The entire state must be persistent allowing the code to effectively act as a predictable function on a state-space)
- All jobs expected to be ACID-verify compliant
 - Not only ACID, but turtles must be able to verify what they did actually happened
  - Verify mutex locks, verify block mined, verify movement done, verify communication packets, verify quarry configuration, and basically everything you literally can
- Jobs have priorities where fueling is highest, ore is second, tunneling is third

## Tunnels
- All tunnels are defined a 2x1 (2 tall, 1 wide) tunnels that are empty for turtles to travel in
- When mining out tunnels, turtles are expected to constantly scan the side of tunnels for potential ores
- Turtles are expected to only dig 2x1 tunnels, and never dig 1x1 tunnels
- There is expected to be at a minimum of 2 block space on each x and y axis between each tunnel to ensure blocks are never "double shown" to the same tunnel
 - Only time this is allowed to break is when connecting tunnels together (duh!)
- Each tunnel has a mutex lock on it ensuring only 1 turtle at a time can travel down it
- Turtles should keep memory of all seen ore veins as they'll need to queue up said job later
 - However, we may have cases where another turtle mining out another vein in which case, we should promptly presume such an ore vein no longer exists

### Layers
- Quarries support layers as in we can create layers which to create tunnels on
- Again, layers are separated by 2 blocks on the y-axis (this is implicit thanks to the tunnel restrictions, but we'll state it regardless)

### Branching algorithm
- Branching should resemble how players typically strip mine
- A main "branch" is first created which all turtle traverse from
- A main up "branch" is created to allow traversal between all layers
- On this main branch, turtles branch off respectively and create strip mines

#### Top-down view per layer
S = spawn column
O = filled
X = to-be-mined/should be mined/mined out
I = inventories


XOOOOOOO
XXXXXXXX
XOOOOOOO
XOOOOOOX
XXXXXXXX
XOOOOOOO
S
I...I

#### Side-view (vertical)

XOOOOOOOSI...I
XXXXXXXXSI...I
XOOOOOOOSI...I
XOOOOOOOSI...I
XXXXXXXXSI...I


- Notice how forward + 1 protects our inventory spaces!!
- We have dug a secondary tunnel "main" tunnel for both vertical and horizontal, this gives us the ability to traverse both!
- Also, despite the prior warnings, the only exception to the no outside of bounding-box rule is on the spawn column where you're allowed to dig up and down

### Ore mining
- Use a flood fill algorithm (ideally BFS)
- Ideally, we can leverage a multi-turtle flood fill algorithm
 - However, given the prior requirements of tunnel mutexes, I am concerned how we would exactly carry this out whilst ensuring we don't also accidentially destroy other turtles

## Fueling
- Turtles should be aware of the job queue and account for how much fuel jobs will take
- Turtles must presume a worse-case scenario when accounting for back-tracking to quarry spawn ensuring that turtles can always make it back to refuel and continue out their tasks
- Turtles should also automatically take fuel from the spawn fuel inventory and refuel themselves ideally using smart algorithm to calculate estimates of how fuel it will cost to carry out queued jobs
 - Intelligently determine how to batch it ie mining a vein should be batched as one operation then refuel, then mine out a tunnel

## Multi-turtle tasking
- Turtles can and will be added/removed seamlessly as stated prior and assumed all added turtles will exist in the spawn column
- Leverage cooperative scheduling algorithms to hand out tasks to turtles to carry out strip mining operations and ore excavation

# Considerations that if, better, we should 100% do
- Quarry wide state-space??
 - All turtles share with each other ore vein locations and state-space generally speaking ensuring that all turtles are aware of each other's ore veins allowing for more efficient allocation of tasks especially for ore excavation

# Watch out for
- How persistence + multi-turtle tasking works together! Ensure that turtles when loaded in can seamlessly mesh back together
- Also, turtles may not load together all at once! This is a serious edge case to consider!
- Upon startup at spawn, turtles should try to refuel!
- Project needs to be kept into a single `main.lua`!
- VALIDATE ALL MINING OPERATIONS AND ENSURE YOU NEVER DIG ANOTHER TURTLE!! 

## Implementation Notes (2025-11-24 build)
- `main.lua` now bootstraps the full runtime: configuration lives under `/state/configs/<quarryId>.json`, turtle state under `/state/turtles/`, jobs under `/state/jobs/`, and verbose logs under `/logs/<quarryId>.log` when enabled.
- The startup wizard guides the quarry config authoring directly on the turtle (text-menu CLI), matching the requirement for interactive installs. Bounding boxes, spawn column data, layer spacing, logging verbosity, and fuel reserves are all captured there.
- Every call into `turtle`, `rednet`, `textutils`, `fs`, and `peripheral` is cross-checked against the CC: Tweaked offline docs mirrored in `cc_docs/tweaked.cc/module/*.html`; the code references those docs in comments and validates API availability before executing.
- Logging is verbose by default (console + optional file). Use menu option `2` at runtime to toggle file logging without editing code; console verbosity is read from config.
- Menu option `3` issues a network-wide recall using `rednet.broadcast` scoped to the quarry protocol, while option `4` enqueues a diagnostic job to exercise the ACID-style job log.
- Scheduler tick currently replays the queue, deterministically claims the highest-priority job, journals the claim, and publishes completion packets so multi-turtle deployments can reconcile state when they come back online.