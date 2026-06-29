# ai-spawn-improved-robz — Roadmap

Living sequence for the flag-intelligence line of work. Each phase ships independently
and is gated on the previous one being verified in a real match.

## Status

| Phase | What it does | State |
|---|---|---|
| 1 — Flag labeling | OWN/CONTESTED/ENEMY + enemy-distance rank → `Context.FlagLabel` | ✅ shipped |
| 2 — Lateral partition (compute+log) | teammate non-overlap split → `Context.FlagOwner` | ✅ shipped |
| Gate | Self-hosted bastogne 2v2: confirm SECTOR/PART logs + playerId contiguous-by-team | ⏸ pending (user runs) |
| 3 — Routing layer | Consume the labels in flag selection (frontier + partition + sector/rank) | ⬜ gated on the Gate |

Specs: `specs/2026-06-28-flag-labeling-design.md`. Plans: `plans/2026-06-28-flag-labeling-phase1.md`, `plans/2026-06-28-flag-labeling-phase2.md`.

## Gate (precondition for Phase 3)

Run a self-hosted bastogne 2v2 with AI on both teams; from game.log confirm:
1. `SECTOR …` lines present, no `SECTOR_FALLBACK` (fingerprint matched).
2. `PART … trusted=true` for every bot (idx in range ⇒ playerId contiguous-by-team holds), confirmed across ≥2 matches.
3. Teammate `mine=true` sets are complementary (no two teammates exclusively own the same flag).
If 2 fails, Phase 3 still ships but the partition stays in its collision-safe own-all mode for that player configuration.

## Phase 3 — Routing layer (design intent)

Wire the existing labels into the flag-SELECTION points so units act on them. The engine's
only movement primitive is `BotApi.Commands:CaptureFlag(squad, flagName)` (it pathfinds to
the chosen flag), so all intelligence is in WHICH flag each squad is ordered to take.

Plug-in points (today both ignore the labels):
- `PickGroupTarget` — the group's shared attack target (main lever).
- `GetFlagToCapture` — fallback/skirmisher weighted pick (optional, same filter).

The selection pipeline, applied before the existing recapture/priority ordering:

```
candidates = enemy-or-neutral flags
  → FRONTIER filter   (flag adjacent to a flag this bot's team owns; never return nil)
  → PARTITION filter  (restrict to this bot's idx-band + shared band, from Context.FlagOwner)
  → ORDER by sector/rank (Context.FlagLabel: prefer CONTESTED then ENEMY by rank)
pick best; if a filter empties the set, fall back to the prior stage (never stall)
```

### Frontier filtering (the one graph feature worth building)

Researched 2026-06-28 (3-agent fan-out). Findings:
- The map has NO built-in adjacency graph; edges must be synthesized from flag coordinates
  (distance threshold ~2200 units, or k-nearest). `map.net` holds a terrain passability grid
  that could weight edges later, but is not needed for v1.
- Of the standard territory-graph patterns (frontier, stepping-stone, flood-fill, graph-cut,
  supply-contiguity), only FRONTIER detection is a real win on this engine. Stepping-stone is
  redundant — `UpdateGroupTargets` already re-targets when a flag falls. Contiguity/supply is
  irrelevant — MoW AS2 has no supply model. Dijkstra is unnecessary at ~11–15 nodes.
- Both reference mods (frontlines-ai, cbyyy) have ZERO spatial logic; flag choice is a
  stateless weighted lottery over ownership. Frontier filtering is the differentiator.

Why frontier matters: today a group can be ordered onto a deep enemy flag; the squad walks
past intermediate enemy flags (fighting, not capturing) and the frontline never advances.
Frontier filtering forces a coherent advance: take the nearest reachable enemy flag, its
capture expands the owned set, the next frontier flag becomes the target.

**Critical historical lesson (from this repo's own code):** a frontline filter existed and was
REMOVED because it "mis-routed squads and stalled them at the spawn point." Root cause: it
returned `nil` when no frontier flag existed (match start before any capture, or after a
collapse). The non-negotiable rule for Phase 3: **frontier-first, then always fall back to any
attackable flag — never return nil while attackable flags exist.**

Build shape:
1. Adjacency: a `neighbors` table per flag. Either precompute offline into `flag_sectors.lua`
   (distance threshold from the x,y already there), or build `FlagAdj` at `OnGameStart` from
   `Context.FlagLabel[*].x/y`. Static for the match.
2. `IsFrontierFlag(name)` — true if any neighbor's `occupant` is this bot's team (or a base).
3. Apply in `PickGroupTarget` (and optionally `GetFlagToCapture`) as the frontier stage above.

### Carry-over Minors the routing layer must address
- **Unmapped flag = ownerless.** On a matched fingerprint, a flag absent from the sector table
  gets no `FlagOwner`/coords entry. The routing filters must treat such a flag as attackable
  (don't drop it) so it is never silently abandoned.
- **3v3 shared band.** `PartitionFlags`' shared-band ownership is currently global, not
  per-boundary — correct for 2v2, wrong for teamSize≥3 (a shared flag would be owned by all
  bots). Fix when 3v3 map data + gate are added: gate `shared` ownership to adjacent bands.

### Phase 3 prerequisites before writing its plan
- Gate above passed (labels + partition correct in-game; playerId assumption confirmed).
- Decide adjacency source (offline table vs OnGameStart build) and the distance threshold,
  validated against bastogne's real flag spacing.
- A fresh spec (brainstorming) for the routing layer, since it changes unit behavior and
  needs its own ASCII design + data-flow diagrams and in-game verification.
