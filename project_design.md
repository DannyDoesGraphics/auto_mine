# Project automine
- CC: Tweaked 1.21.1 turtle auto-miner
- can_push for entities on, do not worry about entities blocking turtle path
- **Always** DuckDuckGo MCP to validate the API you're using from CC: Tweaked is actually correct

## Project goals
- A smart strip tunnel miner that can do work-sharing with multiple other turtles
- Assign 1 turtle as the "master turtle" automatically, and if the master turtle goes down, other turtles are seamlessly take over
- A `tunnel` is defined as a 2x1 (2 tall 1 wide) contigious section (ie turns do not count, rather they should be considered as 2 seperate tunnels)
- Use a local coordinate/orientation system where origin is initialization start
- Persistence is important! Assume that at any moment I can stop the server, restart, have the turtle autostart the program, and assume the program will run perfectly fine!
- The turtle must be self-sustaining, aware of it's own fuel limitations + other turtles
- We will apply a hard bounding box that is oriented to turtle space and given to all turtles
- `turtle` coordinate space refers to the local coordinate space of the bottom most turtle
 - Realistically, we shouldn't ever need to use local space as turtle space is more than sufficient as explained with calibration later

## Tunneling
- Ensure 2 blocks exactly of space between each tunnel including between layers
- We will also layer such strip tunnes ontop of each other ensuring also 2 blocks of space between each layer
- Maintain a conservative approach ensuring we never push outside of our hard defined bounding box limits
- Assume that we will tunnel facing forward
 - Whether to go left or right will be based on bounding box restrictions, if let's say the turtles were placed on the absolute limits of the bounding box ie [0, 64, 64], then the turtles will never go into the x-axis whatsoever
  - btw, when defining our bounding box, we will define simply the other corner point assuming the turtle origin as the second point in the box

### Deposit and rest point
- Assume from turtle origin, that the "behind" spot is the deposit inventory
- Assume from there "left" of the turtle origin, that 

## Multi-turtle threading
- Each tunnel section should be locked behind a "mutex" ensuring 2 turtles cannot travel down the same tunnel
- Upon a fresh start ie non-resume, we will assume all necessary turtles are effectively stacked on top of each other oriented in the same direction
- A "master" turtle is handed to resolve conflicts between turtles ie 2 turtles wanting the same tunnel, but it being claimed or trying to mine or occupy the same space
 - All turtles are expected to all respond and acknowledge all turtle packets to ensure all turtles "agree" with master turtle responsible for handling these conflicts 
  - this protects us from breaking state, and maintains ACID-verify!
- Have another coordinate system called the "turtle" coordinate space which is originated the bottom most turtle's local coordinate system
- A "master" turtle is selected automatically by the turtles and they must all agree on who it is! If the master turtle drops, then turtles will elect another one! This is a very well known algorithm!
 - Make sure all turtles 100% on who the master turtle is
- Ensure we efficiently divide the work between all turtles and if a turtle drops, then we must seamlessly take over it's work

### Adding turtles / calibration
- If a turtle is added mid way through, then we must first calibrate the turtle as we can assume it will be placed on the original turtle stack
 - Usually we can do this by first acquiring a mutex on the relevant tunnel there -> move down until we hit the bottom -> calibrated to turtle space!
- The new turtle should seamlessly mesh into the existing turtle network


## Persistence
- We will introduce a "ACID-verify" system where all actions follow ACID, however, given the restrictions of minecraft, the game may indeed crash during an ACID operation and screw it
 - verify comes in and allows us to verify if such an action was actually performed ie if the server restarts, the turtle should be able to verify it's actions did happen
  - all "ACID-verify" actions should be effectively **everything** from mining, moving, depositing, claiming a mutex, and etc.
-


## Return to home functionality
- Turtles should all try to return home with respect for mutex restrictions
 - Deposit everything
 - Keep some coal
- Upon at "home", the turtles should try to go as far up as they can or until they hit a ceiling which then they stop
- At the end of the process, all turtles should be back to their original stack (orientation doesn't really matter here?)