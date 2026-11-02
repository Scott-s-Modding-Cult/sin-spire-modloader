# Sin Spire Mod Loader

A one-click patch and a small framework for modding Sin Spire, with a set of preset mods. Put each mod in one `Mods` folder, tick the ones you want, and play.

**You need your own copy of Sin Spire.** This repository does not include the game. Nurse Touch's pak does include one mesh cut from the game's player model, as `CREDITS.txt` notes.

## Preset mods

The mods in `mods\` come with the patch and appear in the Mod Manager, where each can be turned on or off.

| Mod | What it does | Keys |
| --- | --- | --- |
| Admin Panel | Cheat panel, opened from a button in the pause menu | Esc |
| Body Visible | First-person body with walk, idle and crouch clips | |
| Crab Pair | Headcrab pair distraction. Silent without Plant Distractor, whose sounds it uses | F9 |
| Creeper Pair | Creeper pair distraction for TutorialCave and Free Mode. Off by default | |
| Ghost Kiss | LostSoul kiss | |
| Monitor Setting | Adds a Monitor row to the video settings | |
| Nurse Touch | Twisted Nurse variation | |
| Plant Distractor | Plant pair distraction placed in each level, with a volume slider | |

These mods are adult content. `sync_mods.ps1` refreshes `mods\` from a game's `Mods` folder. It leaves out personal settings.

## Building the patch

You need Windows, which already includes the compiler this uses, and a copy of [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) that works with the game. The loader was tested with v3.0.1 Beta. UE4SS's `dwmapi.dll` and `ue4ss` folder get packed into the patch.

Double-click **`Build Patch.bat`**. It opens the `dist` folder when it finishes, with `SinSpire-ModLoader-Patch.exe` inside.

It looks for UE4SS in a `ue4ss_files` folder beside the script, then in any Steam copy of the game that has it. If it finds none, it asks you to choose the folder. It takes the patch's icon from your copy of the game when it can find one.

To choose the folders yourself, run the script directly:

```powershell
.\build.ps1 -GameDir "D:\SteamLibrary\steamapps\common\Sin Spire" -Ue4ssDir "C:\path\to\folder\with\dwmapi.dll"
```

## Patching the game

1. Close the game.
2. Run `SinSpire-ModLoader-Patch.exe`. It looks for the game by itself and selects a Steam copy first.
3. Check the folder it chose, then click **Patch Game**.

The patch asks Steam for its libraries and installed games, then checks a running copy of the game, Windows' list of installed programs, the folders around the patch, and common game folders on each drive. If none of those has the game, it searches the top few levels of your drives for up to 8 seconds. If that also fails, it asks you to choose the folder, and it accepts a choice just above or inside the game's folder.

The patch keeps the game's own exe as `SinSpire-Original.exe` and installs the loader as `SinSpire.exe`. Mods already installed in `ue4ss\Mods` or `Content\Paks\~mods` are moved into `Mods`, and each stays on or off as it was. It is safe to run again.

**Remove Patch** puts the original exe back and takes away the links. If the patch installed UE4SS, it removes that too. The `Mods` folder is kept.

A Steam update or file verification restores the game's exe, which turns the loader off. Run the patch again afterwards.

To bring mods to another copy of the game, run the patch from a folder that has a `Mods` folder beside it and choose the other copy.

## Using mods

Put each mod in its own folder:

```
Sin Spire\
  Mods\
    MyMod\
      mod.json              Optional details, described below
      Scripts\main.lua      A UE4SS Lua mod
      Paks\                 .pak, .ucas, .utoc and .sig files for Content\Paks\~mods
      LogicMods\            Files for Content\Paks\LogicMods
      Shared\MyLibrary\     A Lua library other mods can require
```

A mod can have any of these parts, and a plain UE4SS mod works as it is.

Hold **Shift** while starting the game, or run `Mod Manager.bat`, to turn mods on and off and change their order. The window also lists problems such as two mods using the same key.

Every launch, the loader links the enabled mods into the places UE4SS and the engine look for them and writes UE4SS's load order. Mods that are off are removed from those places, but their files stay in `Mods`. The log is `Mods\.modloader\modloader.log`.

Load order applies to Lua mods. Pak files are all mounted, but the list does not set which pak wins when two change the same asset.

## mod.json

Every field is optional.

```json
{
    "title": "My Mod",
    "version": "1.0.0",
    "author": "You",
    "description": "What it does.",
    "requires": ["ModKit"],
    "load_after": ["OtherMod"],
    "keys": ["F2"],
    "enabled_by_default": true,
    "always_on": false,
    "preset": false
}
```

| Field | Meaning |
| --- | --- |
| `requires` | The mod does not load unless these do, and it loads after them. |
| `load_after` | Load after these if they are on, but do not need them. |
| `keys` | Only used to warn about clashes. |
| `always_on` | The Mod Manager will not let this be turned off. |
| `preset` | The Mod Manager says the mod comes with the loader. |

## ModKit

ModKit is a Lua library installed with the loader. Add `"requires": ["ModKit"]` to use it.

```lua
local ModKit = require("ModKit")
local mod = ModKit.new("MyMod")           -- The mod's folder name.

mod.log("Hello")                          -- Goes to UE4SS.log as [MyMod] Hello.
mod.on_key(Key.F2, function() end)        -- A Lua error is logged and the key keeps working.
mod.loop(100, function() end)             -- Game-thread loop that survives errors. Keep to one per mod.
mod.send("MyMod_Value", 5)                -- Mods have separate Lua states, so this is how they talk.
mod.get("MyMod_Value", 0)                 -- Reads it from any mod, with a fallback.
ModKit.is_loaded("OtherMod")              -- Whether the loader started that mod this launch.

local volume = mod.slider({ key = "Volume", label = "My Volume", tab = "audio", min = 0, max = 100, step = 5, default = 50 })
require("ModSettings").StartPolling()     -- Unless the mod already calls ModSettings.Poll() from its own tick.
```

The slider adds a saved row to the game's settings menu. Read `volume.value` to get its value.

## Testing

`tests\test_patch.ps1` runs the patch and launcher against a fake game folder in your temp directory, with no real game files involved. Build first. Holding Shift while it runs opens the Mod Manager, which the test closes before trying again.

## Mod downloads

Some mods are also on the [Releases page](https://github.com/scottricity/sin-spire-modloader/releases) as zips, including ones too big to keep in this repository, such as Backrooms. With the patch installed, unzip one into the game's `Mods` folder and it appears in the Mod Manager. `make_release_zips.ps1` makes the zips.

## Credits

Built on [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS). Not affiliated with the developers of Sin Spire. See [CREDITS.txt](CREDITS.txt) for the creators of the sounds and models the preset mods use.
