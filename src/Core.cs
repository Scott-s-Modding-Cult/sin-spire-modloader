// What the launcher and the patch share: reading the Mods folder, working out the load order, and putting
// the enabled mods where UE4SS and the engine look for them.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;

namespace SinSpireModLoader
{
    class GameFolder
    {
        public readonly string Root;
        public GameFolder(string root) { Root = Path.GetFullPath(root).TrimEnd('\\'); }

        public string Exe { get { return Path.Combine(Root, "SinSpire.exe"); } }
        public string OriginalExe { get { return Path.Combine(Root, "SinSpire-Original.exe"); } }
        public string Win64 { get { return Path.Combine(Root, @"SinSpire\Binaries\Win64"); } }
        public string Shipping { get { return Path.Combine(Win64, "SinSpire-Win64-Shipping.exe"); } }
        public string Ue4ss { get { return Path.Combine(Win64, "ue4ss"); } }
        public string Ue4ssMods { get { return Path.Combine(Ue4ss, "Mods"); } }
        public string Ue4ssShared { get { return Path.Combine(Ue4ssMods, "shared"); } }
        public string ModsTxt { get { return Path.Combine(Ue4ssMods, "mods.txt"); } }
        public string Paks { get { return Path.Combine(Root, @"SinSpire\Content\Paks"); } }
        public string PakMods { get { return Path.Combine(Paks, "~mods"); } }
        public string LogicMods { get { return Path.Combine(Paks, "LogicMods"); } }
        public string Mods { get { return Path.Combine(Root, "Mods"); } }
        public string ModList { get { return Path.Combine(Mods, "modlist.txt"); } }
        public string State { get { return Path.Combine(Mods, ".modloader"); } }
        public string DeployedList { get { return Path.Combine(State, "deployed.txt"); } }
        public string LoadedList { get { return Path.Combine(State, "loaded.txt"); } }
        public string InstallInfo { get { return Path.Combine(State, "install.txt"); } }
        public string LogFile { get { return Path.Combine(State, "modloader.log"); } }

        public bool LooksLikeTheGame
        {
            get { return File.Exists(Shipping) && Directory.Exists(Paks) && (File.Exists(Exe) || File.Exists(OriginalExe)); }
        }

        public bool GameIsRunning()
        {
            foreach (Process process in Process.GetProcessesByName("SinSpire-Win64-Shipping"))
            {
                try
                {
                    if (string.Equals(process.MainModule.FileName, Shipping, StringComparison.OrdinalIgnoreCase)) { return true; }
                }
                catch (Exception)
                {
                    // A process that cannot be inspected is not one this folder started.
                }
            }
            return false;
        }

        public void Log(string message)
        {
            try
            {
                Directory.CreateDirectory(State);
                File.AppendAllText(LogFile, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + message + Environment.NewLine);
            }
            catch (Exception)
            {
                // Logging must never be the reason the game does not start.
            }
        }
    }

    class ModInfo
    {
        public string Name, Title, Version, Author, Description, Dir, Error;
        public List<string> Requires = new List<string>();
        public List<string> LoadAfter = new List<string>();
        public List<string> Keys = new List<string>();
        public bool AlwaysOn, Preset, Enabled = true, EnabledByDefault = true, Active;

        public bool HasScripts { get { return File.Exists(Path.Combine(Dir, @"Scripts\main.lua")); } }
        public string Line { get { return Version == "" ? Title : Title + "  v" + Version; } }
    }

    class Problem
    {
        public readonly string Text;
        public readonly bool Serious; // Serious problems are worth interrupting the launch for.
        public Problem(string text, bool serious) { Text = text; Serious = serious; }
    }

    static class Registry
    {
        static string Text(Dictionary<string, object> json, string key, string fallback)
        {
            object value;
            return json.TryGetValue(key, out value) && value != null ? value.ToString() : fallback;
        }

        static List<string> Names(Dictionary<string, object> json, string key)
        {
            object value;
            var list = new List<string>();
            if (json.TryGetValue(key, out value) && value is IEnumerable && !(value is string))
            {
                foreach (object item in (IEnumerable)value) { list.Add(item.ToString()); }
            }
            return list;
        }

        static ModInfo Read(string dir)
        {
            string manifest = Path.Combine(dir, "mod.json");
            var mod = new ModInfo { Dir = dir, Name = Path.GetFileName(dir), Version = "", Author = "", Description = "" };
            mod.Title = mod.Name;
            if (!File.Exists(manifest))
            {
                // A plain UE4SS or pak mod dropped in works without a manifest.
                bool usable = mod.HasScripts || Directory.Exists(Path.Combine(dir, "Paks"))
                    || Directory.Exists(Path.Combine(dir, "LogicMods")) || Directory.Exists(Path.Combine(dir, "Shared"));
                return usable ? mod : null;
            }
            try
            {
                var json = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(manifest));
                mod.Title = Text(json, "title", mod.Name);
                mod.Version = Text(json, "version", "");
                mod.Author = Text(json, "author", "");
                mod.Description = Text(json, "description", "");
                mod.Requires = Names(json, "requires");
                mod.LoadAfter = Names(json, "load_after");
                mod.Keys = Names(json, "keys");
                mod.AlwaysOn = Text(json, "always_on", "false").ToLowerInvariant() == "true";
                mod.EnabledByDefault = Text(json, "enabled_by_default", "true").ToLowerInvariant() == "true";
                mod.Preset = Text(json, "preset", "false").ToLowerInvariant() == "true";
            }
            catch (Exception error)
            {
                mod.Error = "mod.json could not be read: " + error.Message;
            }
            return mod;
        }

        // Mods in the saved order, with any new ones added after them in alphabetical order.
        public static List<ModInfo> Load(GameFolder game)
        {
            var found = new Dictionary<string, ModInfo>(StringComparer.OrdinalIgnoreCase);
            if (Directory.Exists(game.Mods))
            {
                foreach (string dir in Directory.GetDirectories(game.Mods))
                {
                    if (Path.GetFileName(dir).StartsWith(".")) { continue; }
                    ModInfo mod = Read(dir);
                    if (mod != null) { found[mod.Name] = mod; }
                }
            }
            var ordered = new List<ModInfo>();
            if (File.Exists(game.ModList))
            {
                foreach (string raw in File.ReadAllLines(game.ModList))
                {
                    string line = raw.Trim();
                    if (line.Length < 2 || (line[0] != '+' && line[0] != '-')) { continue; }
                    ModInfo mod;
                    if (found.TryGetValue(line.Substring(1).Trim(), out mod) && !ordered.Contains(mod))
                    {
                        mod.Enabled = line[0] == '+';
                        ordered.Add(mod);
                    }
                }
            }
            foreach (ModInfo mod in found.Values.Where(m => !ordered.Contains(m)).OrderBy(m => m.Name, StringComparer.OrdinalIgnoreCase))
            {
                mod.Enabled = mod.EnabledByDefault;
                ordered.Add(mod);
            }
            return ordered;
        }

        public static void Save(GameFolder game, List<ModInfo> mods)
        {
            var lines = new List<string> { "# Load order, top first. + is enabled, - is disabled. SinSpire.exe -modmanager edits this for you." };
            lines.AddRange(mods.Select(m => (m.Enabled ? "+" : "-") + m.Name));
            Directory.CreateDirectory(game.Mods);
            File.WriteAllLines(game.ModList, lines);
        }

        // Decides which mods run and in what order. Sets Active on each mod and returns the running ones in order.
        public static List<ModInfo> Resolve(List<ModInfo> mods, List<Problem> problems)
        {
            var byName = new Dictionary<string, ModInfo>(StringComparer.OrdinalIgnoreCase);
            foreach (ModInfo mod in mods)
            {
                byName[mod.Name] = mod;
                mod.Active = (mod.Enabled || mod.AlwaysOn) && mod.Error == null;
                if (mod.Error != null && (mod.Enabled || mod.AlwaysOn)) { problems.Add(new Problem(mod.Name + ": " + mod.Error, true)); }
            }

            // Turning one mod off can strand another that needs it, so repeat until nothing changes.
            bool changed = true;
            while (changed)
            {
                changed = false;
                foreach (ModInfo mod in mods.Where(m => m.Active))
                {
                    foreach (string need in mod.Requires)
                    {
                        ModInfo other;
                        if (!byName.TryGetValue(need, out other) || !other.Active)
                        {
                            mod.Active = false;
                            changed = true;
                            problems.Add(new Problem(mod.Name + " was not loaded because it needs " + need + ".", true));
                            break;
                        }
                    }
                }
            }

            var order = new List<ModInfo>();
            var visiting = new HashSet<ModInfo>();
            Action<ModInfo> visit = null;
            visit = mod =>
            {
                if (order.Contains(mod)) { return; }
                if (!visiting.Add(mod))
                {
                    problems.Add(new Problem(mod.Name + " is part of a loop of mods that must load after each other.", false));
                    return;
                }
                foreach (string first in mod.Requires.Concat(mod.LoadAfter))
                {
                    ModInfo other;
                    if (byName.TryGetValue(first, out other) && other.Active) { visit(other); }
                }
                visiting.Remove(mod);
                if (!order.Contains(mod)) { order.Add(mod); }
            };
            foreach (ModInfo mod in mods.Where(m => m.Active)) { visit(mod); }

            var keyOwners = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
            foreach (ModInfo mod in order)
            {
                foreach (string key in mod.Keys)
                {
                    if (!keyOwners.ContainsKey(key)) { keyOwners[key] = new List<string>(); }
                    keyOwners[key].Add(mod.Name);
                }
            }
            foreach (var pair in keyOwners.Where(p => p.Value.Count > 1))
            {
                problems.Add(new Problem("The " + pair.Key + " key is used by " + string.Join(" and ", pair.Value) + ".", false));
            }
            return order;
        }
    }

    static class Deployer
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateHardLink(string link, string existing, IntPtr security);

        static readonly string[] PakExtensions = { ".pak", ".ucas", ".utoc", ".sig" };

        static bool IsJunction(string path)
        {
            return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
        }

        static void MakeJunction(string link, string target)
        {
            var start = new ProcessStartInfo("cmd.exe", "/c mklink /J \"" + link + "\" \"" + target + "\"")
            {
                CreateNoWindow = true,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            using (Process process = Process.Start(start))
            {
                process.StandardOutput.ReadToEnd();
                string error = process.StandardError.ReadToEnd();
                process.WaitForExit();
                if (process.ExitCode != 0) { throw new IOException("Could not link " + link + ": " + error.Trim()); }
            }
        }

        // Hard links need no extra disk space, and the engine sees them as plain files. A copy is the fallback
        // for a file system that has no hard links.
        static void LinkFile(string link, string target)
        {
            if (!CreateHardLink(link, target, IntPtr.Zero)) { File.Copy(target, link); }
        }

        // Takes away everything the last launch set up. Only entries on the list are touched, so files the
        // player put in those folders themselves are safe.
        public static void Undeploy(GameFolder game)
        {
            if (!File.Exists(game.DeployedList)) { return; }
            foreach (string line in File.ReadAllLines(game.DeployedList))
            {
                if (line.Length < 3) { continue; }
                string path = Path.Combine(game.Root, line.Substring(2));
                try
                {
                    if (line[0] == 'J' && Directory.Exists(path) && IsJunction(path)) { Directory.Delete(path); }
                    if (line[0] == 'F' && File.Exists(path)) { File.Delete(path); }
                }
                catch (Exception error)
                {
                    game.Log("Could not remove " + path + ": " + error.Message);
                }
            }
            File.Delete(game.DeployedList);
        }

        static string Relative(GameFolder game, string path)
        {
            return path.Substring(game.Root.Length + 1);
        }

        // mods.txt is the only way to give UE4SS a load order. The game's other entries keep their settings, and
        // Keybinds stays last because UE4SS's own file says it must.
        public static void WriteModsTxt(GameFolder game, List<ModInfo> all, List<ModInfo> active)
        {
            if (!Directory.Exists(game.Ue4ssMods)) { return; }
            var managed = new HashSet<string>(all.Select(m => m.Name), StringComparer.OrdinalIgnoreCase);
            var others = new List<string>();
            string keybinds = "Keybinds : 1";
            if (File.Exists(game.ModsTxt))
            {
                foreach (string raw in File.ReadAllLines(game.ModsTxt))
                {
                    string line = raw.Trim();
                    int colon = line.IndexOf(':');
                    if (line.StartsWith(";") || colon < 0) { continue; }
                    string name = line.Substring(0, colon).Trim();
                    // An entry whose folder is gone is a mod that was deleted, and would stay on the list forever.
                    if (managed.Contains(name) || !Directory.Exists(Path.Combine(game.Ue4ssMods, name))) { continue; }
                    if (name.Equals("Keybinds", StringComparison.OrdinalIgnoreCase)) { keybinds = line; }
                    else { others.Add(line); }
                }
            }
            var lines = new List<string>(others);
            lines.AddRange(active.Where(m => m.HasScripts).Select(m => m.Name + " : 1"));
            lines.Add("");
            lines.Add("; Built-in keybinds, do not move up!");
            lines.Add(keybinds);
            File.WriteAllLines(game.ModsTxt, lines);
        }

        public static List<Problem> Deploy(GameFolder game)
        {
            var problems = new List<Problem>();
            Directory.CreateDirectory(game.State);
            File.WriteAllText(game.LogFile, "");
            if (game.GameIsRunning())
            {
                game.Log("The game is running, so the mods were left as they are.");
                return problems;
            }

            Undeploy(game);
            List<ModInfo> mods = Registry.Load(game);
            List<ModInfo> active = Registry.Resolve(mods, problems);
            var deployed = new List<string>();
            try
            {
                Directory.CreateDirectory(game.PakMods);
                foreach (ModInfo mod in active) { DeployMod(game, mod, deployed, problems); }
            }
            finally
            {
                File.WriteAllLines(game.DeployedList, deployed);
            }
            WriteModsTxt(game, mods, active);
            File.WriteAllLines(game.LoadedList, active.Select(m => m.Name + "=" + m.Version));

            foreach (ModInfo mod in active) { game.Log("Loaded " + mod.Line); }
            foreach (ModInfo mod in mods.Where(m => !m.Active)) { game.Log("Not loaded: " + mod.Line); }
            foreach (Problem problem in problems) { game.Log("Problem: " + problem.Text); }
            return problems;
        }

        static void DeployMod(GameFolder game, ModInfo mod, List<string> deployed, List<Problem> problems)
        {
            if (mod.HasScripts)
            {
                // A junction keeps ue4ss\Mods\<name> a real path, so scripts that build paths from it still work.
                string link = Path.Combine(game.Ue4ssMods, mod.Name);
                if (Directory.Exists(link))
                {
                    problems.Add(new Problem(mod.Name + " was not loaded because a folder of that name is already in ue4ss\\Mods.", true));
                }
                else
                {
                    // enabled.txt would start the mod a second way, outside the load order.
                    File.Delete(Path.Combine(mod.Dir, "enabled.txt"));
                    MakeJunction(link, mod.Dir);
                    deployed.Add("J|" + Relative(game, link));
                }
            }

            string sharedDir = Path.Combine(mod.Dir, "Shared");
            if (Directory.Exists(sharedDir))
            {
                foreach (string library in Directory.GetDirectories(sharedDir))
                {
                    string link = Path.Combine(game.Ue4ssShared, Path.GetFileName(library));
                    if (Directory.Exists(link))
                    {
                        problems.Add(new Problem(mod.Name + ": the shared library " + Path.GetFileName(library) + " is already installed, so this copy was skipped.", false));
                        continue;
                    }
                    Directory.CreateDirectory(game.Ue4ssShared);
                    MakeJunction(link, library);
                    deployed.Add("J|" + Relative(game, link));
                }
            }

            LinkPaks(game, mod, Path.Combine(mod.Dir, "Paks"), game.PakMods, deployed, problems);
            LinkPaks(game, mod, Path.Combine(mod.Dir, "LogicMods"), game.LogicMods, deployed, problems);
        }

        static void LinkPaks(GameFolder game, ModInfo mod, string from, string to, List<string> deployed, List<Problem> problems)
        {
            if (!Directory.Exists(from)) { return; }
            Directory.CreateDirectory(to);
            foreach (string file in Directory.GetFiles(from).Where(f => PakExtensions.Contains(Path.GetExtension(f).ToLowerInvariant())))
            {
                string link = Path.Combine(to, Path.GetFileName(file));
                if (File.Exists(link))
                {
                    problems.Add(new Problem(mod.Name + ": " + Path.GetFileName(file) + " is already in the game's mod folder, so this copy was skipped.", true));
                    continue;
                }
                LinkFile(link, file);
                deployed.Add("F|" + Relative(game, link));
            }
        }
    }
}
