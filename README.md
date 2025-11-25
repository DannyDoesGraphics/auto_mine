# AutoMine – deployment guide

This document explains how to copy the turtle controller onto CC: Tweaked robots, run it manually, and keep it running automatically after reboots.

## 1. Prerequisites
- Minecraft instance with CC: Tweaked 1.21.1 (or newer) installed.
- Mining turtles equipped with diamond tools, a modem (wired or wireless), and access to fuel plus an empty inventory slot facing the home chest.
- HTTP enabled in your `ComputerCraft` config if you plan to download files via `wget`.

## 2. Importing the program onto a turtle
On the turtle, decide on a workspace directory (the default root works fine) and run:

```lua
mkdir automine
cd automine
wget https://raw.githubusercontent.com/DannyDoesGraphics/auto_mine/main/main.lua main.lua
wget https://raw.githubusercontent.com/DannyDoesGraphics/auto_mine/main/project_design.md project_design.md
```

Notes:
- If HTTP is disabled, copy the files using a disk drive or the ComputerCraft `pastebin`/`gist` workflow instead.
- The script will create `automine_config.json` on first launch. Edit it later with `edit automine_config.json` to adjust bounding boxes, fuel targets, etc.

## 3. Running manually
From the `automine` directory, start the controller with:

```lua
lua main.lua
```

Optional arguments:
- `lua main.lua /path/to/config.json` – load a non-default config file.

When the program boots it will:
1. Create/refresh `automine_state.json`, `automine_acid.json`, and `automine.log`.
2. Open any attached modem for the `auto_mine/v1` protocol.
3. Start the leader-election heartbeat, tunnel planner, and worker loop.

Stop the program with `Ctrl+T`.

## 4. Enabling auto-run on reboot
Create a `startup.lua` next to `main.lua` so the turtle relaunches automatically after crashes or server restarts:

```lua
echo 'shell.run("automine/main.lua")' > /startup.lua
```

Or, if your files live in `automine/`, use:

```lua
cd /
edit startup.lua
```

and insert:

```lua
shell.run("automine/main.lua")
```

For a custom config path, pass it through:

```lua
shell.run("automine/main.lua", "automine/custom_config.json")
```

The startup script will now launch AutoMine every time the turtle turns on, allowing it to recover in the exact state recorded in the ACID journal.

## 5. Multi-turtle bring-up checklist
- Place all turtles in the same stack facing the same direction before powering them on.
- Confirm each turtle has a unique computer ID (`id` command).
- Ensure every turtle can reach the shared deposit chest located directly behind their origin.
- Start all turtles (or let startup.lua do it). They will elect a master automatically and divvy up tunnels.

That’s it—once the turtles finish tunneling they’ll return home, deposit inventory, and climb above the stack awaiting the next assignment.
