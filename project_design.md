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
- Each quarry has a configured **bounding box** size which is the second point defined relative the turtle space where [origin, second_point] defines the box
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
XOOOOOOO
XXXXXXXX
XOOOOOOO
S
I...I

#### Side-view (vertical)

OOOOOOOOSI...I
XXXXXXXXSI...I
OOOOOOOOSI...I
OOOOOOOOSI...I
XXXXXXXXSI...I

### Ore mining
- Use a flood fill algorithm
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

## Implementation architecture

- **Bootstrap CLI**
 - Every turtle boots into a guided CLI that captures/validates the quarry id, bounding box, tunnel spacing, spawn orientation, and spawn column inventory depth.
 - CLI first broadcasts a `config_request` for that quarry. If another turtle replies with a signed config blob, we persist it and skip the questions. Otherwise, the CLI walks the user through defining the config and persists it as `<quarry_id>_config.json` so new turtles can request it over the network.
- **Config propagation**
 - Configs carry a monotonically increasing `configVersion`. Whenever any field changes (bounding box, spacing, spawn offsets, recall flag, etc.) the current master turtle broadcasts `config_update` with the full payload. Receivers persist the blob, reconcile their local plans, and verify they sit inside the bounding box—if not, they enqueue a `return_home` job immediately.

## State & persistence

- `state.json` is purely turtle-scoped metadata (pose, calibration offsets, current job, local cache of quarry snapshot).
- `quarry_state.json` mirrors the shared quarry space and contains:
 - `version`, `quarryId`, `jobs` (priority queue), `tunnels`, `oreRegistry`, `tunnelLocks`, `recallSignal`, and `journal.nextId`.
- ACID compliance comes from a single `journal.json` file that records every side-effect (movement, dig, inspect results, job assignment, lock mutations, deposits, rednet exchanges). Each record embeds a replay closure name; on resume we call the verifier before removing the record.
- Every mutation bumps `quarry_state.version`. Masters broadcast this version in heartbeats so that any turtle can become master and still have the latest snapshot.

## Job model

- Jobs live in a persisted min-heap keyed by `(priority, createdAt)`. Current priorities are:
 1. `refuel` (spawn column fuel chest interaction and verification of gained fuel levels)
 2. `ore_mine` (flood-fill ore excavation + verification that each mined block disappeared)
 3. `tunnel_mine` (strip tunnels obeying the 2×1 with 2-block spacing rule)
 4. `recall` (return-to-home jobs triggered by config recall flag or explicit command)
- Jobs require a `lockSet`, and turtles verify they still own the locks before each state transition. If verification fails, the job rolls back and re-enters the queue.

## Movement & calibration

- Calibration routine:
 - Attempt to move down until `turtle.down()` fails; if blocked by another turtle, move up to sit above stack, wait exponentially, and retry.
 - Record the resulting Y as `calibratedFloor`. The turtle above uses the shared turtle-space origin derived from the bottom-most turtle’s calibration record.
 - Movement helpers enforce bounding box containment before issuing any turtle commands and log every action via ACID journal entries referencing the CC: Tweaked `turtle` API (validated against https://tweaked.cc/module/turtle.html ).

## Tunnel execution & ore scanning

- Each tunnel step performs a 6-face scan:
 - Inspect forward-bottom, forward-top (via `turtle.inspect()` and `turtle.inspectUp()` after clearing the block), then rotate left to inspect left-bottom/left-top, rotate right twice to inspect right-bottom/right-top, finally re-center.
 - Detected ore blocks enqueue/refresh `ore_mine` jobs keyed by their absolute turtle-space coordinates.
- Strip tunnels are always carved 2 blocks tall, 1 wide. Turtles never break spacing constraints as chunk planners allocate coordinates spaced by `tunnelSpacing` horizontally and `layerSpacing` vertically.

## Spawn column & inventory contract

- Spawn column anchors at turtle-space (0,0,0); “behind” the turtle is negative Z. Deposits/fueling occur by walking to `spawnOffset`, facing back, and interacting with the chest stack behind (down-most chest = fuel-only).
- Deposits skip up to `depositKeepCoal` fuel items for autonomy. Fuel retrieval verifies the resulting level meets or exceeds the requested reserve before committing the journal entry.

## Networking & commands

- Message types: `heartbeat`, `config_request`, `config_update`, `state_sync`, `job_request`, `job_assign`, `job_release`, `recall`, `home_ack`.
- Heartbeats (every `heartbeatInterval`) include job summaries and config version to keep everyone in sync.
- A `recall` broadcast (triggered from any turtle CLI or an external controller computer) causes every turtle to enqueue a highest-priority `recall` job that returns them to spawn, deposits inventory, and idles until recall cleared.

## Failure handling

- Every API action is retried with exponential back-off while respecting bounding boxes.
- Resume logic replays outstanding journal entries, reacquires locks, revalidates job ownership, and only then proceeds.
- State mismatches (config version drift, out-of-bounds pose) generate blocking jobs so turtles cannot continue destructive work until the operator intervenes through the CLI.