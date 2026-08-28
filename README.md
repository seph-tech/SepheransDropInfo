# Sepheran's Drop Info


![WoW](https://img.shields.io/badge/WoW-3.3.5a-c79c6e)
![Server](https://img.shields.io/badge/Ascension-f0b429)
![Lua](https://img.shields.io/badge/Lua-5.1-2c2d72)
![Dependencies](https://img.shields.io/badge/dependencies-none-2ea44f)

Sepheran's Drop Info is a World of Warcraft Wrath 3.3.5 addon that builds a personal loot database as you play. It watches the mobs you loot, records observed item drops and coin, then shows drop-rate information directly on mob mouseover tooltips and inside a dashboard.

<img width="571" height="432" alt="Screenshot_417" src="https://github.com/user-attachments/assets/45eb6f0e-cbc9-447d-b640-7ae2a9967ce0" />
<img width="1404" height="804" alt="Screenshot_416" src="https://github.com/user-attachments/assets/2f7a2e99-cef1-4de6-abe4-6ed4df558828" />


## Support development

If the addon has been useful and you would like to support me and my sanity, you can ...

| Method | Link |
| --- | --- |
| **Paypal** | [buy me a beer through PayPal](https://paypal.me/sephnar) |
| **ko-fi** | [support me on ko-fi](https://ko-fi.com/sepheran) |


## Features

- Adds observed item drop rates to creature mouseover tooltips.
- Shows total and average coin observed from each mob.
- Adds an accuracy indicator so high drop rates are easier to judge:
  - Low: 0-19 loot opens
  - Medium: 20-49 loot opens
  - High: 50-99 loot opens
  - Precise: 100+ loot opens
- Tracks mobs, loot opens, item quantities, money, zones, first seen, and last seen data.
- Provides a draggable in-game dashboard with Browser, Analytics, Sync, Saves, and Export tabs.
- Supports syncing observed data with other addon users through guild, party, raid, whisper, and an optional custom channel.
- Flags suspicious sync data and quarantines obviously malformed data before it can corrupt the visible database.
- Saves and restores database snapshots.
- Exports a readable plain text version of the observed database.

## Installation

1. Download or clone this repository.
2. Place the `SepheransDropInfo` folder into your WoW AddOns directory:

   ```text
   /AddOns/SepheransDropInfo
   ```

3. Restart the game or run:

   ```text
   /reload
   ```

4. Open the addon with:

   ```text
   /sdi
   ```

## How It Works

When you kill and loot a creature, the addon records the loot window contents against that mob's NPC ID. Each loot window open counts as one observation.

Drop rates are calculated from observed data:

```text
drop rate = item seen count / loot opens
```

Example:

```text
Silk Cloth: 27.3% (3 drops seen across 11 loot opens)
```

Because early observations can be misleading, the tooltip includes an accuracy label based on loot opens. A 100% drop rate from one loot open is marked Low accuracy, while a 100% drop rate from 100+ loot opens is marked Precise.

## Dashboard

Open the dashboard with `/sdi` or by clicking the minimap button.

### Browser

Browse observed mobs, search by mob or item name, and sort by:

- Name
- Loot opens
- Money

Selecting a mob shows its observed drops, drop rates, coin totals, average coin per open, and zones seen.

### Analytics

Shows high-level database stats, including:

- Observed mobs
- Loot opens
- Total coin
- Average coin per open
- Unique items seen
- Top mobs by opens
- Richest mobs
- Best average coin per open
- Top items seen

### Sync

Discovers other Sepheran's Drop Info users and allows exchanging raw observed data.

The Sync table shows:

- User
- Mobs
- Opens
- Unique Loot
- To Sync
- Flags

Use **Refresh Users** to discover online users and check how many mobs appear newer or missing from your database. Use **Sync Now** after selecting a user to request their observed data.

The custom Channel field can be used for addon discovery outside guild, party, or raid. Type a channel name and click **Join Channel** to join that channel.

Sync trust flags are a warning system, not a perfect anti-cheat system. Clean data is merged normally, questionable data can be marked for review, and clearly suspicious data is quarantined so it does not contaminate the active observed database.

### Saves

Create and manage database snapshots. Snapshots can be useful before syncing, testing, or resetting data.

The addon can also create an automatic login snapshot when enabled.

### Export

Generates a readable text export of the observed database.

The export includes each mob name, NPC ID, loot opens, primary zone, and item drop percentages:

```text
Kurzen Commando (ID 938)
  Loot opens: 11
  Primary zone: Stranglethorn Vale
  Drops:
    - Silk Cloth: 27.3% (3/11)
    - Tough Cloak: 9.1% (1/11)
```

## Tooltip

When hovering a mob with recorded data, the tooltip shows:

- Observed item drops
- Drop percentages
- Total coin
- Average coin per open
- Accuracy label

Only the top observed drops are shown on the tooltip to keep it readable. The dashboard contains the fuller view.

## Commands

```text
/sdi
```

Open the dashboard.

```text
/sdi help
```

Print available commands.

```text
/sdi browser
/sdi analytics
/sdi sync
/sdi saves
/sdi export
```

Open a specific dashboard tab.

```text
/sdi sort
```

Cycle the mob browser sort mode.

```text
/sdi top
```

Print the top observed mobs using the current sort mode.

```text
/sdi session
```

Print current session totals.

```text
/sdi hide
/sdi show
/sdi toggle
```

Control whether tooltip drop information is shown.

```text
/sdi status
```

Print basic database and addon status.

```text
/sdi verbose
```

Toggle verbose logging.

```text
/sdi dump
```

Print recent addon log entries.

```text
/sdi reset
```

Reset the current realm database while preserving saved snapshots.

## Data Storage

Data is stored in WoW SavedVariables under:

```text
SepheransDropInfoDB
```

The database is separated by realm. It stores local observations, synced sources, quarantined sync sources, trust flags, logs, snapshots, settings, and export text.

## Author

Created by Sepheran.

