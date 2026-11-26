# Changelog

## Unreleased

- `.toc`: addon list icon, category, German notes, website and license fields
- MIT license
- Addon files moved to the repository root, so the repo can be cloned straight into `AddOns/NodoTracker`

## 1.1.0 – 2026-11-26

- Window rebuilt from the parts of Blizzard's damage meter (atlases, dropdown templates, menu system)
- `[time]` top left, yellow dropdown for This Session / Overall, gear menu, minimize button
- Rows: Level (ETA, % / XP left / current / max), Experience (/h, kills + quests + other), Gold (/h, net, income / spending)
- Kill XP detected via the localized XP chat message (combat log is not available to addons on 12.x)
- Quest XP via `QUEST_TURNED_IN`
- Settings moved into Blizzard's Options → AddOns
- Fixed: "blocked from an action" popup caused by registering `COMBAT_LOG_EVENT_UNFILTERED`
- Fixed: addon aborted on load (font strings without font, removed `OptionsSliderTemplate`)
- Slash command is now `/ntr` (also `/nodotracker`); `/ntr debug` added

## 1.0.0 – 2026-11-26

- First version: XP and gold for this session and overall
