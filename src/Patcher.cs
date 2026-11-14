// Installing and removing the mod loader in a game: UE4SS and ModKit (carried in this program), this program itself as
// the game's SinSpire.exe, and the preset mods from the mod list. It moves mods already installed the old ways into the
// Mods folder, and can undo all of it. The Mod Manager's Mod Loader tab and the --patch and --unpatch modes run it.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;


namespace SinSpireModLoader
{
    static class Patch
    {
        const string LoaderProduct = "SinSpire Mod Loader";
        const string LastPatchWithPresets = "patch-2026.11.14";
        const long OldMonitorLauncherSize = 6656; // The launcher used before this one has no product name to check.
        const string ManagerBat = "Mod Manager.bat";
        static readonly HashSet<string> Ue4ssOwnMods = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "BPML_GenericFunctions", "BPModLoaderMod", "CheatManagerEnablerMod", "ConsoleCommandsMod",
            "ConsoleEnablerMod", "Keybinds", "LineTraceMod", "SplitScreenMod", "shared",
            "ActorDumperMod", "jsbLuaProfilerMod", // Only in UE4SS 3.0.1 and older.
        };

        static Stream Resource(string name)
        {
            return Assembly.GetExecutingAssembly().GetManifestResourceStream(name);
        }

        // The release this patch is, such as patch-2026.11.14, written in by scripts\build.ps1. The launcher compares it with
        // GitHub's newest to offer updates.
        public static string Tag
        {
            get
            {
                using (Stream stream = Resource("version.txt"))
                {
                    if (stream == null) { return null; }
                    using (var reader = new StreamReader(stream)) { return reader.ReadToEnd().Trim(); }
                }
            }
        }

        enum Replace { Never, Always, WhenNewer }

        static void ExtractZip(string resource, string to, Replace replace)
        {
            using (var zip = new ZipArchive(Resource(resource), ZipArchiveMode.Read))
            {
                foreach (ZipArchiveEntry entry in zip.Entries)
                {
                    if (entry.Name == "") { continue; }
                    string path = Path.Combine(to, entry.FullName.Replace('/', '\\'));
                    if (File.Exists(path))
                    {
                        if (replace == Replace.Never) { continue; }
                        if (replace == Replace.WhenNewer && entry.LastWriteTime.UtcDateTime <= File.GetLastWriteTimeUtc(path).AddSeconds(2)) { continue; }
                    }
                    Directory.CreateDirectory(Path.GetDirectoryName(path));
                    entry.ExtractToFile(path, true);
                }
            }
        }

        public static bool IsLauncher(string exe)
        {
            return File.Exists(exe) && (FileVersionInfo.GetVersionInfo(exe).ProductName == LoaderProduct
                || new FileInfo(exe).Length == OldMonitorLauncherSize);
        }

        static void InstallLauncher(GameFolder game, Action<string> say)
        {
            if (!IsLauncher(game.Exe))
            {
                // Not a launcher, so it is the real game exe, possibly newer than any earlier backup after a Steam update.
                if (!File.Exists(game.Exe)) { throw new IOException("SinSpire.exe is missing from " + game.Root); }
                File.Copy(game.Exe, game.OriginalExe, true);
                say("Kept the game's own exe as SinSpire-Original.exe.");
            }
            else if (!File.Exists(game.OriginalExe))
            {
                throw new IOException("SinSpire-Original.exe is missing. Verify the game's files in Steam, then patch again.");
            }
            // The launcher is this program: in the game folder as SinSpire.exe it starts the game with the mods.
            if (!string.Equals(App.Self, game.Exe, StringComparison.OrdinalIgnoreCase))
            {
                File.Copy(App.Self, game.Exe, true);
            }
            say("Installed the mod loader as SinSpire.exe.");
        }

        // The mods are made and tested for the UE4SS the patch carries, and a mod with a C++ part (a dll) only loads in
        // that exact build, so the game always ends up with it. Any other UE4SS is set aside, and Remove Patch puts it back.
        const string Ue4ssDllEntry = @"ue4ss\UE4SS.dll";
        const string Ue4ssBackupName = "ue4ss_before_patch";
        const string Ue4ssAddedList = "added_by_patch.txt";
        // A player's own UE4SS settings and load order stay when their UE4SS is replaced.
        static readonly HashSet<string> Ue4ssPlayerFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            @"ue4ss\UE4SS-settings.ini", @"ue4ss\Mods\mods.txt",
        };

        static string Ue4ssBackup(GameFolder game) { return Path.Combine(game.State, Ue4ssBackupName); }

        static string Sha256(Stream stream)
        {
            using (var sha = SHA256.Create()) { return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", ""); }
        }

        static string Sha256(string file)
        {
            using (Stream stream = File.OpenRead(file)) { return Sha256(stream); }
        }

        // The SHA-256 of the UE4SS.dll this patch carries.
        public static string BundledUe4ssSha256()
        {
            using (var zip = new ZipArchive(Resource("ue4ss.zip"), ZipArchiveMode.Read))
            {
                ZipArchiveEntry entry = zip.Entries.First(e => string.Equals(e.FullName.Replace('/', '\\'), Ue4ssDllEntry, StringComparison.OrdinalIgnoreCase));
                using (Stream stream = entry.Open()) { return Sha256(stream); }
            }
        }

        // Where the UE4SS being replaced came from, which decides what is kept of it.
        enum Ue4ssOrigin
        {
            Player,       // Installed some other way: kept in the backup, and Remove Patch puts it back.
            PlayerKept,   // An earlier patch already kept the player's own one: that backup stays as it is.
            Patch,        // An earlier patch installed it, so Remove Patch takes it away: nothing to keep.
        }

        // UE4SS 3.0.1 and older keep everything straight in Win64, and its proxy dll loads that copy, not the one in the
        // ue4ss folder. Its mods move to where the patch adopts mods from, keeping whether each was on, and the rest goes
        // into the backup.
        static void MoveFlatUe4ss(GameFolder game, string backup)
        {
            string flatMods = Path.Combine(game.Win64, "Mods");
            if (Directory.Exists(flatMods))
            {
                var on = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                string list = Path.Combine(flatMods, "mods.txt");
                if (File.Exists(list))
                {
                    foreach (string line in File.ReadAllLines(list))
                    {
                        Match entry = Regex.Match(line.Trim('﻿', ' ', '\t'), @"^([^;:]+?)\s*:\s*1$");
                        if (entry.Success) { on.Add(entry.Groups[1].Value); }
                    }
                }
                Directory.CreateDirectory(game.Ue4ssMods);
                foreach (string dir in Directory.GetDirectories(flatMods))
                {
                    string name = Path.GetFileName(dir);
                    string target = Path.Combine(game.Ue4ssMods, name);
                    if (Ue4ssOwnMods.Contains(name) || Directory.Exists(target)) { continue; }
                    Directory.Move(dir, target);
                    if (on.Contains(name)) { File.WriteAllText(Path.Combine(target, "enabled.txt"), ""); }
                }
            }
            foreach (string name in new[] { "UE4SS.dll", "UE4SS-settings.ini", "UE4SS_Signatures", "Mods" })
            {
                string path = Path.Combine(game.Win64, name);
                string kept = Path.Combine(backup, name);
                if (File.Exists(path)) { File.Move(path, kept); }
                else if (Directory.Exists(path)) { Directory.Move(path, kept); }
            }
        }

        // Puts the patch's UE4SS over another one. A player's own UE4SS is kept, and Remove Patch puts it back.
        static void ReplaceUe4ss(GameFolder game, bool flat, Ue4ssOrigin origin, Action<string> say)
        {
            string backup = Ue4ssBackup(game);
            string list = Path.Combine(backup, Ue4ssAddedList);
            var added = new List<string>();
            if (origin == Ue4ssOrigin.Player)
            {
                if (Directory.Exists(backup)) { Directory.Delete(backup, true); }
                Directory.CreateDirectory(backup);
                if (flat) { MoveFlatUe4ss(game, backup); }
            }
            else if (origin == Ue4ssOrigin.PlayerKept && File.Exists(list))
            {
                added.AddRange(File.ReadAllLines(list).Where(l => l.Trim() != ""));
            }
            using (var zip = new ZipArchive(Resource("ue4ss.zip"), ZipArchiveMode.Read))
            {
                foreach (ZipArchiveEntry entry in zip.Entries)
                {
                    if (entry.Name == "") { continue; }
                    string relative = entry.FullName.Replace('/', '\\');
                    string path = Path.Combine(game.Win64, relative);
                    // Beside a flat UE4SS, the ue4ss folder is not part of the old install, as an earlier patch put it there.
                    bool oldFile = origin == Ue4ssOrigin.Player && (!flat || !relative.StartsWith(@"ue4ss\", StringComparison.OrdinalIgnoreCase));
                    if (File.Exists(path))
                    {
                        if (Ue4ssPlayerFiles.Contains(relative)) { continue; }
                        if (oldFile)
                        {
                            string kept = Path.Combine(backup, relative);
                            Directory.CreateDirectory(Path.GetDirectoryName(kept));
                            File.Copy(path, kept, true);
                        }
                    }
                    else if (oldFile || (origin == Ue4ssOrigin.PlayerKept && !added.Contains(relative, StringComparer.OrdinalIgnoreCase)))
                    {
                        added.Add(relative);
                    }
                    Directory.CreateDirectory(Path.GetDirectoryName(path));
                    entry.ExtractToFile(path, true);
                }
            }
            if (origin != Ue4ssOrigin.Patch) { File.WriteAllLines(list, added); }
            if (origin == Ue4ssOrigin.Player)
            {
                say("Replaced UE4SS with the build the mods are made for. The one that was installed is kept in Mods\\.modloader\\"
                    + Ue4ssBackupName + " and comes back if the patch is removed.");
            }
            else
            {
                say("Updated UE4SS to the build the mods are made for.");
            }
        }

        static void RestoreUe4ss(GameFolder game, Action<string> say)
        {
            string backup = Ue4ssBackup(game);
            if (!Directory.Exists(backup)) { return; }
            string list = Path.Combine(backup, Ue4ssAddedList);
            if (File.Exists(list))
            {
                foreach (string relative in File.ReadAllLines(list).Where(l => l.Trim() != ""))
                {
                    string path = Path.Combine(game.Win64, relative);
                    if (File.Exists(path)) { File.Delete(path); }
                }
            }
            foreach (string kept in Directory.GetFiles(backup, "*", SearchOption.AllDirectories))
            {
                if (string.Equals(kept, list, StringComparison.OrdinalIgnoreCase)) { continue; }
                string path = Path.Combine(game.Win64, kept.Substring(backup.Length + 1));
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                File.Copy(kept, path, true);
            }
            Directory.Delete(backup, true);
            say("Put back the UE4SS that was installed before the patch.");
        }

        static bool InstallUe4ss(GameFolder game, Action<string> say)
        {
            string dll = Path.Combine(game.Ue4ss, "UE4SS.dll");
            bool flat = File.Exists(Path.Combine(game.Win64, "UE4SS.dll"));
            if (flat)
            {
                ReplaceUe4ss(game, true, Ue4ssOrigin.Player, say);
                // The ue4ss folder is the patch's own next to a flat UE4SS, so Remove Patch takes it away.
                return true;
            }
            if (File.Exists(dll) && Sha256(dll) != BundledUe4ssSha256())
            {
                bool patchInstalled = File.Exists(game.InstallInfo) && File.ReadAllText(game.InstallInfo).Contains("ue4ss_added=1");
                Ue4ssOrigin origin = patchInstalled ? Ue4ssOrigin.Patch
                    : Directory.Exists(Ue4ssBackup(game)) ? Ue4ssOrigin.PlayerKept : Ue4ssOrigin.Player;
                ReplaceUe4ss(game, false, origin, say);
                return false;
            }
            bool present = File.Exists(Path.Combine(game.Win64, "dwmapi.dll")) && File.Exists(dll);
            if (present)
            {
                say("UE4SS is already the build the mods are made for.");
                return false;
            }
            ExtractZip("ue4ss.zip", game.Win64, Replace.Never);
            say("Installed UE4SS.");
            return true;
        }

        // A mod in a folder beside this program comes along, which is how mods reach a second copy of the game.
        static void BringModsFromBesideThePatch(GameFolder game, Action<string> say)
        {
            var beside = new GameFolder(AppDomain.CurrentDomain.BaseDirectory);
            if (string.Equals(beside.Mods, game.Mods, StringComparison.OrdinalIgnoreCase) || !Directory.Exists(beside.Mods)) { return; }
            foreach (string dir in Directory.GetDirectories(beside.Mods).Where(d => !Path.GetFileName(d).StartsWith(".")))
            {
                string target = Path.Combine(game.Mods, Path.GetFileName(dir));
                if (Directory.Exists(target)) { continue; }
                CopyFolder(dir, target);
                say("Copied " + Path.GetFileName(dir) + ".");
            }
            if (File.Exists(beside.ModList) && !File.Exists(game.ModList)) { File.Copy(beside.ModList, game.ModList); }
        }

        static void CopyFolder(string from, string to)
        {
            Directory.CreateDirectory(to);
            foreach (string file in Directory.GetFiles(from)) { File.Copy(file, Path.Combine(to, Path.GetFileName(file))); }
            foreach (string dir in Directory.GetDirectories(from)) { CopyFolder(dir, Path.Combine(to, Path.GetFileName(dir))); }
        }

        // Moves mods installed the old way into Mods\<name>, keeping whether each was turned on.
        static void AdoptInstalledMods(GameFolder game, Action<string> say)
        {
            var disabled = new List<string>();
            if (Directory.Exists(game.Ue4ssMods))
            {
                foreach (string dir in Directory.GetDirectories(game.Ue4ssMods))
                {
                    string name = Path.GetFileName(dir);
                    if (Ue4ssOwnMods.Contains(name) || (File.GetAttributes(dir) & FileAttributes.ReparsePoint) != 0) { continue; }
                    string target = Path.Combine(game.Mods, name);
                    if (Directory.Exists(target))
                    {
                        say("Left ue4ss\\Mods\\" + name + " where it is, because Mods\\" + name + " already exists.");
                        continue;
                    }
                    if (!File.Exists(Path.Combine(dir, "enabled.txt"))) { disabled.Add(name); }
                    Directory.Move(dir, target);
                    say("Moved " + name + " into the Mods folder.");
                }
            }

            // Pak files are matched to a mod by name, and a pak with no matching script becomes a mod of its own.
            if (Directory.Exists(game.PakMods))
            {
                foreach (string file in Directory.GetFiles(game.PakMods))
                {
                    string extension = Path.GetExtension(file).ToLowerInvariant();
                    if (extension != ".pak" && extension != ".ucas" && extension != ".utoc" && extension != ".sig") { continue; }
                    string name = Regex.Replace(Path.GetFileNameWithoutExtension(file), @"^SinSpire-|_P$", "");
                    string target = Path.Combine(game.Mods, name, "Paks");
                    Directory.CreateDirectory(target);
                    File.Move(file, Path.Combine(target, Path.GetFileName(file)));
                }
            }

            // ModKit brings its own copy of this library, and two copies would collide.
            string oldLibrary = Path.Combine(game.Ue4ssShared, "ModSettings");
            if (Directory.Exists(oldLibrary) && (File.GetAttributes(oldLibrary) & FileAttributes.ReparsePoint) == 0)
            {
                Directory.Delete(oldLibrary, true);
            }

            if (disabled.Count > 0)
            {
                List<ModInfo> mods = Registry.Load(game);
                foreach (ModInfo mod in mods.Where(m => disabled.Contains(m.Name, StringComparer.OrdinalIgnoreCase))) { mod.Enabled = false; }
                Registry.Save(game, mods);
            }
        }

        public static void Apply(GameFolder game, Action<string> say)
        {
            if (!game.LooksLikeTheGame) { throw new IOException(game.Root + " does not look like a Sin Spire folder."); }
            if (game.GameIsRunning()) { throw new IOException("Close the game first."); }
            Directory.CreateDirectory(game.State);
            // Patches up to patch-2026.11.14 carried the preset mods and put them all in; later ones install them from
            // mods.json. A game patched by one of those already had every preset, so one missing now was removed on purpose.
            string earlierTag = Updater.InstalledTag(game);
            bool patchedBefore = File.Exists(game.InstallInfo) || File.Exists(game.OriginalExe) || IsLauncher(game.Exe);
            bool hadBundledPresets = patchedBefore && (earlierTag == null || string.CompareOrdinal(earlierTag, LastPatchWithPresets) <= 0);
            Deployer.Undeploy(game);
            bool addedUe4ss = InstallUe4ss(game, say);
            if (!addedUe4ss && File.Exists(game.InstallInfo)) { addedUe4ss = File.ReadAllText(game.InstallInfo).Contains("ue4ss_added=1"); }
            File.WriteAllText(game.InstallInfo, "ue4ss_added=" + (addedUe4ss ? "1" : "0") + Environment.NewLine +
                (Tag != null ? "patch=" + Tag + Environment.NewLine : ""));

            ExtractZip("modkit.zip", game.Mods, Replace.Always);
            BringModsFromBesideThePatch(game, say);
            AdoptInstalledMods(game, say);

            // The credits for the assets the preset mods use.
            using (Stream from = Resource("CREDITS.txt"))
            using (Stream to = File.Create(Path.Combine(game.Mods, "CREDITS.txt")))
            {
                from.CopyTo(to);
            }
            // Comes after adopting, so an installed copy of a preset is moved in first and left as it is.
            Importer.InstallPresets(game, hadBundledPresets, say);

            InstallLauncher(game, say);
            File.WriteAllText(Path.Combine(game.Root, ManagerBat), "@start \"\" \"%~dp0SinSpire.exe\" -modmanager\r\n");

            List<Problem> problems = Deployer.Deploy(game);
            foreach (Problem problem in problems) { say("Problem: " + problem.Text); }
            say("Done. " + Registry.Load(game).Count(m => m.Enabled) + " mods are on. Add mods to the Mods folder, and hold Shift while starting the game to choose which ones load.");
        }

        public static void Remove(GameFolder game, Action<string> say)
        {
            if (game.GameIsRunning()) { throw new IOException("Close the game first."); }
            Deployer.Undeploy(game);
            Deployer.WriteModsTxt(game, Registry.Load(game), new List<ModInfo>());

            if (IsLauncher(game.Exe) && File.Exists(game.OriginalExe))
            {
                File.Delete(game.Exe);
                File.Move(game.OriginalExe, game.Exe);
                say("Restored the game's own SinSpire.exe.");
            }
            string bat = Path.Combine(game.Root, ManagerBat);
            if (File.Exists(bat)) { File.Delete(bat); }

            if (File.Exists(game.InstallInfo) && File.ReadAllText(game.InstallInfo).Contains("ue4ss_added=1"))
            {
                File.Delete(Path.Combine(game.Win64, "dwmapi.dll"));
                Directory.Delete(game.Ue4ss, true);
                File.Delete(game.InstallInfo);
                say("Removed UE4SS.");
            }
            RestoreUe4ss(game, say);
            say("Patch removed. Your mods are still in the Mods folder but will not load.");
        }
    }
}
