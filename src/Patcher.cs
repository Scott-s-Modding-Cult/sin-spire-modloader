// The one-click patch: a single program holding the launcher, UE4SS and ModKit. It works out which game folder to
// patch, moves any mods already installed into the Mods folder, and can undo all of it.
//   SinSpire-ModLoader-Patch.exe                     Opens the window.
//   SinSpire-ModLoader-Patch.exe --patch "<folder>"    Patches without a window. The exit code is 0 on success.
//   SinSpire-ModLoader-Patch.exe --unpatch "<folder>"  Removes the patch without a window.
//   SinSpire-ModLoader-Patch.exe --find "<file>" [<choice>...]  Writes what the search finds, for testing.
//   SinSpire-ModLoader-Patch.exe --no-search         Opens the window as if no game were found, for testing.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;

[assembly: AssemblyProduct("SinSpire Mod Loader Patch")]
[assembly: AssemblyTitle("Sin Spire Mod Loader Patch")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace SinSpireModLoader
{
    static class Patch
    {
        const string LoaderProduct = "SinSpire Mod Loader";
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

        static bool IsLauncher(string exe)
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
            using (Stream from = Resource("launcher.exe"))
            using (Stream to = File.Create(game.Exe))
            {
                from.CopyTo(to);
            }
            say("Installed the mod loader as SinSpire.exe.");
        }

        // The mods loop with this, which UE4SS 3.0.1, the last stable release, does not have. Without it they never start.
        const string Ue4ssNeededFunction = "LoopInGameThreadWithDelay";
        const string Ue4ssBackupName = "ue4ss_before_patch";
        const string Ue4ssAddedList = "added_by_patch.txt";
        // A player's own UE4SS settings and load order stay when their UE4SS is replaced.
        static readonly HashSet<string> Ue4ssPlayerFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            @"ue4ss\UE4SS-settings.ini", @"ue4ss\Mods\mods.txt",
        };

        static string Ue4ssBackup(GameFolder game) { return Path.Combine(game.State, Ue4ssBackupName); }

        // Lua function names are stored as plain text in the dll.
        static bool HasNeededFunction(string dll)
        {
            byte[] bytes = File.ReadAllBytes(dll);
            byte[] name = Encoding.ASCII.GetBytes(Ue4ssNeededFunction);
            for (int start = 0; start <= bytes.Length - name.Length; start++)
            {
                if (bytes[start] != name[0]) { continue; }
                int matched = 1;
                while (matched < name.Length && bytes[start + matched] == name[matched]) { matched++; }
                if (matched == name.Length) { return true; }
            }
            return false;
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

        // Puts the patch's UE4SS over an older one. What it replaces is kept, and Remove Patch puts it back.
        static void ReplaceUe4ss(GameFolder game, bool flat, Action<string> say)
        {
            string backup = Ue4ssBackup(game);
            if (Directory.Exists(backup)) { Directory.Delete(backup, true); }
            Directory.CreateDirectory(backup);
            if (flat) { MoveFlatUe4ss(game, backup); }
            var added = new List<string>();
            using (var zip = new ZipArchive(Resource("ue4ss.zip"), ZipArchiveMode.Read))
            {
                foreach (ZipArchiveEntry entry in zip.Entries)
                {
                    if (entry.Name == "") { continue; }
                    string relative = entry.FullName.Replace('/', '\\');
                    string path = Path.Combine(game.Win64, relative);
                    // Beside a flat UE4SS, the ue4ss folder is not part of the old install, as an earlier patch put it there.
                    bool oldFile = !flat || !relative.StartsWith(@"ue4ss\", StringComparison.OrdinalIgnoreCase);
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
                    else if (oldFile)
                    {
                        added.Add(relative);
                    }
                    Directory.CreateDirectory(Path.GetDirectoryName(path));
                    entry.ExtractToFile(path, true);
                }
            }
            File.WriteAllLines(Path.Combine(backup, Ue4ssAddedList), added);
            say("Updated UE4SS, as the installed one is too old for the mods. The old one is kept in Mods\\.modloader\\"
                + Ue4ssBackupName + " and comes back if the patch is removed.");
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
            if (flat || (File.Exists(dll) && !HasNeededFunction(dll)))
            {
                ReplaceUe4ss(game, flat, say);
                // The ue4ss folder is the patch's own next to a flat UE4SS, so Remove Patch takes it away.
                return flat;
            }
            bool present = File.Exists(Path.Combine(game.Win64, "dwmapi.dll")) && File.Exists(dll);
            if (present)
            {
                say("UE4SS is already installed, so it was left as it is.");
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
            Deployer.Undeploy(game);
            bool addedUe4ss = InstallUe4ss(game, say);
            if (!addedUe4ss && File.Exists(game.InstallInfo)) { addedUe4ss = File.ReadAllText(game.InstallInfo).Contains("ue4ss_added=1"); }
            File.WriteAllText(game.InstallInfo, "ue4ss_added=" + (addedUe4ss ? "1" : "0") + Environment.NewLine);

            ExtractZip("modkit.zip", game.Mods, Replace.Always);
            BringModsFromBesideThePatch(game, say);
            AdoptInstalledMods(game, say);

            // Comes after adopting, so an installed copy of a preset is moved in first. A file only gets replaced when
            // the patch's copy is newer, so a mod rebuilt locally and a player's settings both survive.
            ExtractZip("presets.zip", game.Mods, Replace.WhenNewer);
            say("Added the preset mods to the Mods folder.");

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

    static class PatchProgram
    {
        [STAThread]
        static int Main(string[] args)
        {
            if (args.Length == 2 && (args[0] == "--patch" || args[0] == "--unpatch"))
            {
                var game = new GameFolder(args[1]);
                var report = new List<string>();
                try
                {
                    if (args[0] == "--patch") { Patch.Apply(game, report.Add); }
                    else { Patch.Remove(game, report.Add); }
                    foreach (string line in report) { game.Log(line); }
                    return 0;
                }
                catch (Exception error)
                {
                    report.Add("Failed: " + error);
                    foreach (string line in report) { game.Log(line); }
                    return 1;
                }
            }
            if (args.Length >= 2 && args[0] == "--find")
            {
                var lines = GameSearch.Quick().Select(f => "quick|" + f.Source + "|" + f.Folder).ToList();
                lines.AddRange(GameSearch.Drives().Select(f => "drives|" + f.Source + "|" + f.Folder));
                foreach (string choice in args.Skip(2)) { lines.Add("choice|" + choice + "|" + GameSearch.ResolveChoice(choice)); }
                File.WriteAllLines(args[1], lines);
                return 0;
            }
            Application.EnableVisualStyles();
            Application.Run(new PatchForm(args.Contains("--no-search")));
            return 0;
        }
    }

    class PatchForm : Form
    {
        readonly ComboBox folder = new ComboBox { Dock = DockStyle.Fill };
        readonly TextBox output = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical };
        readonly Label status = new Label { AutoSize = true };
        readonly Button browse = new Button { Text = "Browse...", AutoSize = true };
        readonly Button patch = new Button { Text = "Patch Game", AutoSize = true };
        readonly Button remove = new Button { Text = "Remove Patch", AutoSize = true };
        readonly Dictionary<string, string> sources = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        public PatchForm(bool skipSearch)
        {
            Text = "Sin Spire Mod Loader Patch";
            AutoScaleDimensions = new SizeF(96F, 96F);
            AutoScaleMode = AutoScaleMode.Dpi;
            ClientSize = new Size(640, 380);
            MinimumSize = new Size(480, 300);
            StartPosition = FormStartPosition.CenterScreen;

            browse.Click += (s, e) => AskForFolder("Choose the Sin Spire folder, the one with SinSpire.exe in it.");
            folder.SelectedIndexChanged += (s, e) => ShowSource();
            patch.Click += (s, e) => Run(Patch.Apply);
            remove.Click += (s, e) =>
            {
                if (MessageBox.Show(this, "Remove the mod loader from this game? Your Mods folder is kept.", Text, MessageBoxButtons.OKCancel) == DialogResult.OK)
                {
                    Run(Patch.Remove);
                }
            };

            var buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, FlowDirection = FlowDirection.RightToLeft };
            buttons.Controls.AddRange(new Control[] { patch, remove });
            var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 5, Padding = new Padding(8) };
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            var label = new Label { Text = "Game folder", AutoSize = true };
            layout.Controls.Add(label, 0, 0);
            layout.SetColumnSpan(label, 2);
            layout.Controls.Add(folder, 0, 1);
            layout.Controls.Add(browse, 1, 1);
            layout.Controls.Add(status, 0, 2);
            layout.SetColumnSpan(status, 2);
            layout.Controls.Add(output, 0, 3);
            layout.SetColumnSpan(output, 2);
            layout.Controls.Add(buttons, 0, 4);
            layout.SetColumnSpan(buttons, 2);
            Controls.Add(layout);

            Shown += (s, e) => Search(skipSearch);
        }

        void Search(bool skip)
        {
            List<FoundGame> quick = skip ? new List<FoundGame>() : GameSearch.Quick();
            if (quick.Count > 0 || skip)
            {
                Finish(quick);
                return;
            }

            // Nothing obvious, so look through the drives without freezing the window.
            status.Text = "Looking for the game on your drives...";
            patch.Enabled = remove.Enabled = browse.Enabled = false;
            Task.Factory.StartNew(() => GameSearch.Drives()).ContinueWith(task =>
            {
                patch.Enabled = remove.Enabled = browse.Enabled = true;
                Finish(task.IsFaulted ? new List<FoundGame>() : task.Result);
            }, TaskScheduler.FromCurrentSynchronizationContext());
        }

        void Finish(List<FoundGame> found)
        {
            foreach (FoundGame game in found)
            {
                sources[game.Folder] = game.Source;
                folder.Items.Add(game.Folder);
            }
            if (found.Count > 0)
            {
                folder.SelectedIndex = 0;
                return;
            }
            status.Text = "The game was not found. Choose its folder with Browse.";
            AskForFolder("Sin Spire was not found on this PC. Choose its folder, the one with SinSpire.exe in it.");
        }

        void ShowSource()
        {
            string source;
            status.Text = sources.TryGetValue(folder.Text, out source) ? "Found: " + source + "." : "";
        }

        // Keeps asking until the choice is the game or the person gives up.
        void AskForFolder(string message)
        {
            using (var dialog = new FolderBrowserDialog { Description = message })
            {
                while (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    string chosen = GameSearch.ResolveChoice(dialog.SelectedPath);
                    if (chosen != null)
                    {
                        sources[chosen] = "Chosen by you";
                        folder.Text = chosen;
                        ShowSource();
                        return;
                    }
                    MessageBox.Show(this, "Sin Spire was not found in that folder. Choose the folder with SinSpire.exe in it.", Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
            }
        }

        void Run(Action<GameFolder, Action<string>> action)
        {
            output.Clear();
            Action<string> say = line => { output.AppendText(line + Environment.NewLine); output.Update(); };
            try
            {
                string chosen = GameSearch.ResolveChoice(folder.Text);
                if (chosen == null)
                {
                    say("Sin Spire was not found in that folder. Choose the folder with SinSpire.exe in it.");
                    return;
                }
                folder.Text = chosen;
                action(new GameFolder(chosen), say);
            }
            catch (Exception error)
            {
                say("Failed: " + error.Message);
            }
        }
    }
}
