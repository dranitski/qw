---
name: dcss_game_knowledge
description: DCSS game mechanics relevant to bot play — branches, resistances, runes, dangers, Zot clock
type: project
---

## Branch Difficulty and Runes (seed 1 GrBe)

### Branch Order (by difficulty)
D:1-11 → Lair:1-5 → D:12-15 → Orc:1-2 → Spider:1-4 → Shoals:1-4 →
Vaults:1-4 → Depths:1-4 → Elf:1-3 → Crypt:1-3 → Slime:1-5 → Vaults:5 → Zot:1-5

### Rune Options for 3-Rune Win
- **Spider rune** (gossamer): Reliable, good for axe users
- **Shoals rune** (barnacled): Watch for Ilsuiw (mesmerise)
- **Slime rune** (slimy): Easy WITH rCorr, deadly without. Bot has Omysa armour (rCorr)
- **Vaults rune** (silver): Vaults:5 is extremely dangerous. Vault wardens seal stairs.
- For seed 1: Spider + Shoals + Slime was the winning combination

### Deadly Monsters by Area
- **Depths**: stone giant, ettin, sun moth (fire), salamander tyrant (fire+melee), tengu reaver
- **Vaults:5**: vault warden (seals stairs!), vault sentinel, ancient lich
- **Zot**: orb of fire (rF immune, ranged), Killer Klown (random damage), electric golem (rElec immune), draconian packs
- **Elf**: deep elf annihilator (crystal spear), master archer (bolts), demonologists

### Key Resistances
- **rCorr**: Critical for Slime Pits (acid damage everywhere)
- **rF**: Critical for Zot (orbs of fire), important for Depths (fire dragons)
- **rElec**: Important for Zot (electric golems, storm dragons)
- **Will+**: Important for Elf (mesmerise, paralysis from deep elves)

### Vaults Lock-In
- Entering Vaults with 0 runes: door slams shut, locked until Vaults rune obtained
- Entering with 1+ runes: NOT locked, can freely leave
- The lock check is at the ENTRANCE, checked once on entry

### Dangerous Mechanics
- **Distortion weapons**: Can banish to Abyss. Sonja carries one.
- **Mesmerise**: Prevents movement away from mesmeriser. Ilsuiw, merfolk avatars
- **Berserk cooldown**: Slowed + exhausted after berserk ends. Vulnerable period.
- **Runed doors**: Alert nearby monsters when opened. Elf:1 has 8 of them.
- **Zot clock**: Staying too long on the same level drains max HP permanently (~1000 turns per tick). Bot stuck on D:10 for 30K turns had HP drain from 84 → 3. This is NOT a bug — it's DCSS's anti-stalling mechanic.

### Exclusions in DCSS
- Exclusions mark map areas as "don't path through" for autoexplore
- Created by `travel.set_exclude(x, y)` with default radius ~7 tiles
- A single excluded monster can block off large map sections
- Autoexplore reports "Partly explored" when exclusions block reachable areas
- Without exclusions: autoexplore may loop endlessly trying to reach unreachable areas
