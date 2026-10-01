# Eight Trigrams Furnace — milestone 7 prototype: treasures and rewards

Four classes (glaive, bow, dao, scholar) in the Reed Marsh cave: the little
demons guard the gourd, the Horned Kings guard the jade vase and a peach of
immortality. Solo or LAN co-op. The plan for the remaining dungeons is in
`DESIGN.md`. The toad arena from earlier milestones remains for tuning combat.
Placeholder geometry throughout.

## Run (Linux)
Install Godot 4.6, then open this folder in the editor and press F5, or:

    godot --path .

The start menu offers a class, then the cave or the arena, solo or hosted, or
**Join** (type the host's address). The host's screen shows its LAN address. The host needs
UDP port 24565 open (e.g. `sudo ufw allow 24565/udp` if a firewall is on).
From a terminal: `godot --path . -- --host --level reed_marsh` or
`godot --path . -- --join 192.168.1.20`; add `--class bow` (or glaive, dao,
scholar) to choose a class.

## Controls
| Action | Keyboard | Mouse | Gamepad |
|---|---|---|---|
| Move | WASD | | left stick |
| Light | J | left | X |
| Heavy | K | right | Y |
| Special | L or Shift | | right bumper |
| Dodge | Space | | A |
| Gourd: draw in / pour out | I or E | | left bumper |
| Toggle cursor aiming | F2 | | |
| Restart (solo or host only) | R | | Start |

Attacks go where you face, turning toward an enemy within about 40° ahead
(the bow and talisman use a narrower, longer-reaching cone).

## Classes
Each class solves a different problem in a fight; the special (block button)
expresses it most clearly.

| | Glaive | Bow | Dao | Scholar |
|---|---|---|---|---|
| Plays for | holding ground | keeping distance | staying in motion | controlling the fight |
| Light | 3-hit sweeping combo | snap shot, 14 m | fast 4-hit combo; a dodge cancels it at any instant | 3 fan cuts; the third gusts enemies back |
| Heavy | tap: thrust · hold: 360° sweep | hold to draw (slowed); a full draw pierces the line and staggers | dash through enemies, invulnerable, hitting all on the path | tap: talisman seals a toad in place · hold: gale knocks back and interrupts any warning |
| Special | hold to block; press just before a hit to parry | kick: shove an enemy away | counter stance: struck in the window, even by a red attack, you strike from behind; otherwise you're exposed | ward: a circle that heals whoever stands in it |
| Qi from | light hits | snap-shot hits | hits and perfect dodges (which also speed the combo briefly) | fastest passive regeneration |
| Health · speed | 100 · normal | 80 · normal | 85 · fast | 75 · normal |

A sealed toad counts as weakened: the gourd can draw it in. Specializations
(two per class) are planned for later.

## The cave and the gourd
Two little demons, Clever Devil and Wily Worm, carry the gourd; beat them and
it waits on its pedestal. Clever Devil calls your name (purple: don't act),
a smaller version of what the Silver King does later. The gourd holds one
thing at a time (two once you have the jade vase):
- **Water** from a pool (which drains it, leaving dry ground) or a spring.
- **Fire** from a lit brazier (which puts it out) or an eternal flame.
- **A weakened small toad** (flattened or stunned).

With room in the gourd, facing a source draws it in. Otherwise the gourd
pours into what you face whatever it accepts: fire lights braziers and burns
brambles; water douses fire walls, fills basins and puts out braziers. Released into nothing,
the oldest contents go: fire scorches and water splashes the enemies in front
of you, and a toad is flung straight ahead, striking the first enemy and
landing dazed. **Springs heal** whoever stands in them. The gourd
reaches about 4.5 m, in front of you, within your room.

A door opens when everything sharing its link is done (braziers lit, basin
filled, chest opened, its toads beaten), and stays open. Springs and eternal
flames never run out, so wasting water or fire cannot make the cave
unwinnable. Enemies only engage players in their own room, and one carried
out of it (by a dash or a shove) walks back.

The map is `levels/reed_marsh.txt`: a terrain grid and a link grid, with the
legend at the top of the file.

## The Horned Kings
The hall at the end of the cave holds two bosses; the exit stays sealed until
both fall.
- **Golden Horned King** (the brawler): a wide sword sweep (gold warning:
  parry it and his posture suffers badly) and a leaping slam (red ring; run
  out of it, since a dodge alone won't carry you clear).
- **Silver Horned King** (the trickster): keeps his distance, fans fire along
  the ground (red cone), and calls one player's name (purple beam and ring).
  Purple means don't act: an attack, special or gourd use during the call is
  answering, and draws you into his jade vase, where you lose health for a few
  seconds. The first 0.3 s of a call don't count (reaction time). Moving and
  dodging are always fine. An unanswered call leaves him flustered and open.
  Striking him hard shakes a trapped ally loose.
- **Poise:** hits, kicks, counters, seals, gales and parries wear down a
  king's posture; when it breaks he is helpless for a moment.
- **Twins:** when one falls, the other is enraged (faster, more aggressive).
- **Rewards:** their fall unseals two pedestals beside the exit: the **jade
  vase** (joins the gourd as a second chamber, whoever picks it up) and a
  **peach of immortality** (+25 maximum health for every player).

Warning colours across the game: red = get out of the way, gold = parryable,
purple = don't act. Elements have one colour each wherever they appear
(fire orange, water blue); objects are told apart by shape.

## Cheats (for testing; solo or host)
Press ` (backtick) to open the console, type, Enter to run:
`god` · `heal` · `class glaive|bow|dao|scholar` (keeps health as a fraction,
qi, gourd, vase, contents and peaches) · `give gourd|vase|peach` · `kill`
(everything in your room) · `open` (every door) · `warp start|demons|kings|exit`
or `warp X Y` (a map tile) · `help`.

## Co-op rules
- Each extra player adds 60% more small toads per wave and 50% more health
  to big toads.
- A toad targets the nearest standing player, but its leap hits everyone on
  the ring and its tongue hits the first player along the line. Enemies notice
  only players in a room they share; a doorway belongs to both rooms it joins.
- Downed players are revived by an ally standing beside them for 3 seconds
  (back at half health). If everyone is down, the host presses R.
- Hit-stop (the brief freeze on a hit) is off in networked games: a freeze of
  the shared simulation would stall every player.

## Reading the toad
- **Compressed, trembling, red ring**: leap onto the ring. Unblockable; get off it.
- **Reared back, throat turning gold, gold line**: tongue lash. Parry it (press
  block just before it lands) to sever the tongue; a held block also stops it
  (costs qi); or sidestep.
- **Flat and pale**: recovering. Hit it.

## Qi (blue bar)
Thrust 30, sweep 40. Blocked hits drain qi; without enough the guard breaks.
Dodges and parries are free. Light hits restore qi; it also refills slowly.

## How the networking works
The host simulates everything. Each tick it sends every client one compact
binary snapshot (about 560 bytes in a busy wave); each client sends back one
intent packet for its own player. Presses travel as running counts, so a lost
packet cannot swallow a button press. Clients simulate nothing: they place
and draw what the snapshot describes, and every warning marker is computed
from the replicated state.

**Known limit:** clients see their own character about one round trip late.
On a LAN that is a few milliseconds; over the internet it would be noticeable,
and needs client-side prediction (a later milestone).

## Code layout
`player.gd` holds what every class shares (movement, dodge, health, qi, the
gourd, replication); each class is a kit in `kits/` (light, heavy, special,
weapon). The player reads one `Intent` per tick from an input source: the
keyboard (`local_input.gd`), a remote client (`remote_input.gd`), or a test
bot. `dungeon.gd` and `prop.gd` build a dungeon from a text map in `levels/`.

## Tuning
Shared player numbers: top of `player.gd`. Each class: top of its file in
`kits/`. Toads: top of `toad.gd`. Waves and co-op scaling:
top of `main.gd`.

## Tests
    godot --headless --path . --fixed-fps 60 -s tests/combat_test.gd
    godot --headless --path . --fixed-fps 60 -s tests/session_test.gd
    godot --headless --path . --fixed-fps 60 -s tests/gourd_test.gd
    godot --headless --path . --fixed-fps 60 -s tests/class_test.gd
    godot --headless --path . --fixed-fps 60 -s tests/boss_test.gd
    godot --headless --path . --fixed-fps 60 -s tests/rewards_test.gd
    godot --headless --path . -s tests/cave_design_test.gd
    godot --headless --path . --fixed-fps 60 -s tests/cave_walkthrough.gd

Deterministic checks of the combat rules, the snapshot encoding, the session
rules, and the gourd rules. `cave_design_test` explores every state a player
can reach in the cave and checks that the exit stays reachable from all of
them (no soft-locks). `cave_walkthrough` plays the cave start to finish in the
real game, following the solver's plan (add `-- --class NAME` to play it
with another class). `class_test` checks the rules that make each class
distinct. Run it with `-- --host --level reed_marsh`
while a client joins, and both print the final state of every prop for comparison.

    godot --headless --path . --fixed-fps 60 -- --selftest
    godot --headless --path . -- --host --selftest --frames 1800
    godot --headless --path . -- --join 127.0.0.1 --selftest --frames 2400

Scripted bots play solo, or as host and client in two terminals. These show
that the code runs end to end over a real connection; their results say
nothing about balance.
