// Works out where Sin Spire is installed. The quick checks ask Steam and Windows, and only look at places that could
// plausibly hold the game. Searching the drives is slower, so it is kept for when those find nothing.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace SinSpireModLoader
{
    class FoundGame
    {
        public readonly string Folder, Source;
        public FoundGame(string folder, string source) { Folder = folder; Source = source; }
    }

    static class GameSearch
    {
        const string GameName = "Sin Spire";
        const int MaxDepth = 4;
        static readonly TimeSpan DriveSearchLimit = TimeSpan.FromSeconds(8);

        static readonly string[] SteamRegistryKeys =
        {
            @"HKEY_CURRENT_USER\Software\Valve\Steam|SteamPath",
            @"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Valve\Steam|InstallPath",
            @"HKEY_LOCAL_MACHINE\SOFTWARE\Valve\Steam|InstallPath",
        };

        // Where people commonly keep Steam libraries and games, tried on every fixed drive.
        static readonly string[] CommonFolders =
        {
            @"SteamLibrary\steamapps\common\Sin Spire",
            @"Steam\steamapps\common\Sin Spire",
            @"Program Files (x86)\Steam\steamapps\common\Sin Spire",
            @"Program Files\Steam\steamapps\common\Sin Spire",
            @"Games\SteamLibrary\steamapps\common\Sin Spire",
            @"Games\Steam\steamapps\common\Sin Spire",
            @"Games\Sin Spire",
            @"Sin Spire",
        };

        static readonly HashSet<string> FoldersNotWorthSearching = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "Windows", "ProgramData", "$Recycle.Bin", "System Volume Information", "Recovery", "PerfLogs",
            "AppData", "node_modules", ".git",
        };

        static IEnumerable<string> FixedDrives()
        {
            return DriveInfo.GetDrives().Where(d => d.DriveType == DriveType.Fixed && d.IsReady).Select(d => d.RootDirectory.FullName);
        }

        static void Add(List<FoundGame> found, string folder, string source)
        {
            try
            {
                string full = Path.GetFullPath(folder).TrimEnd('\\');
                if (new GameFolder(full).LooksLikeTheGame && !found.Any(f => f.Folder.Equals(full, StringComparison.OrdinalIgnoreCase)))
                {
                    found.Add(new FoundGame(full, source));
                }
            }
            catch (Exception)
            {
                // A path that cannot be read cannot be the game.
            }
        }

        static IEnumerable<string> SteamInstalls()
        {
            foreach (string entry in SteamRegistryKeys)
            {
                string[] parts = entry.Split('|');
                string path = null;
                try { path = Microsoft.Win32.Registry.GetValue(parts[0], parts[1], null) as string; }
                catch (Exception) { }
                if (!string.IsNullOrEmpty(path)) { yield return path.Replace('/', '\\'); }
            }
        }

        // Steam lists its libraries in libraryfolders.vdf. Old versions of the file use numbers as the keys.
        static List<string> SteamLibraries()
        {
            var libraries = new List<string>();
            foreach (string steam in SteamInstalls())
            {
                libraries.Add(steam);
                try
                {
                    string list = Path.Combine(steam, @"steamapps\libraryfolders.vdf");
                    if (!File.Exists(list)) { continue; }
                    foreach (Match match in Regex.Matches(File.ReadAllText(list), "\"(?:path|\\d+)\"\\s+\"([A-Za-z]:[^\"]+)\""))
                    {
                        libraries.Add(match.Groups[1].Value.Replace(@"\\", @"\"));
                    }
                }
                catch (Exception)
                {
                    // The main Steam folder can still be checked without the list.
                }
            }
            return libraries.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        }

        // Steam's manifest names the game's folder, which covers a library where that folder is not the usual one.
        static void AddFromSteam(List<FoundGame> found)
        {
            foreach (string library in SteamLibraries())
            {
                string apps = Path.Combine(library, "steamapps");
                Add(found, Path.Combine(apps, "common", GameName), "Steam");
                try
                {
                    if (!Directory.Exists(apps)) { continue; }
                    foreach (string manifest in Directory.GetFiles(apps, "appmanifest_*.acf"))
                    {
                        string text = File.ReadAllText(manifest);
                        if (!Regex.IsMatch(text, "\"name\"\\s+\"" + GameName + "\"", RegexOptions.IgnoreCase)) { continue; }
                        Match folder = Regex.Match(text, "\"installdir\"\\s+\"([^\"]+)\"");
                        if (folder.Success) { Add(found, Path.Combine(apps, "common", folder.Groups[1].Value), "Steam"); }
                    }
                }
                catch (Exception)
                {
                    // One unreadable library should not stop the others being checked.
                }
            }
        }

        static void AddRunningGame(List<FoundGame> found)
        {
            foreach (Process process in Process.GetProcessesByName("SinSpire-Win64-Shipping"))
            {
                try
                {
                    // Shipping exe -> Win64 -> Binaries -> SinSpire -> the game's folder.
                    string win64 = Path.GetDirectoryName(process.MainModule.FileName);
                    Add(found, Path.GetFullPath(Path.Combine(win64, @"..\..\..")), "Currently running");
                }
                catch (Exception)
                {
                    // A process that cannot be inspected tells us nothing.
                }
            }
        }

        // Windows' list of installed programs covers installers that are not Steam.
        static void AddFromInstalledPrograms(List<FoundGame> found)
        {
            string[] roots = { @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" };
            var hives = new[] { Microsoft.Win32.Registry.CurrentUser, Microsoft.Win32.Registry.LocalMachine };
            foreach (var hive in hives)
            {
                foreach (string root in roots)
                {
                    try
                    {
                        using (var uninstall = hive.OpenSubKey(root))
                        {
                            if (uninstall == null) { continue; }
                            foreach (string name in uninstall.GetSubKeyNames())
                            {
                                using (var program = uninstall.OpenSubKey(name))
                                {
                                    string title = program == null ? null : program.GetValue("DisplayName") as string;
                                    string location = program == null ? null : program.GetValue("InstallLocation") as string;
                                    if (title != null && location != null && title.IndexOf(GameName, StringComparison.OrdinalIgnoreCase) >= 0)
                                    {
                                        Add(found, location, "Installed program");
                                    }
                                }
                            }
                        }
                    }
                    catch (Exception)
                    {
                        // A key that cannot be read is skipped.
                    }
                }
            }
        }

        // The patch may have been run from inside a game folder, however deep.
        static void AddFromAroundThePatch(List<FoundGame> found)
        {
            string folder = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
            while (!string.IsNullOrEmpty(folder))
            {
                Add(found, folder, "Around this patch");
                folder = Path.GetDirectoryName(folder);
            }
        }

        // The checks that take no noticeable time. Steam comes first, so a Steam copy is the one selected.
        public static List<FoundGame> Quick()
        {
            var found = new List<FoundGame>();
            AddFromSteam(found);
            AddRunningGame(found);
            AddFromInstalledPrograms(found);
            AddFromAroundThePatch(found);
            foreach (string drive in FixedDrives())
            {
                foreach (string common in CommonFolders)
                {
                    Add(found, Path.Combine(drive, common), common.Contains("steamapps") ? "Steam library" : "Common folder");
                }
            }
            return found;
        }

        // Folders with these in their names are searched first at each level, in case time runs out.
        static bool LooksPromising(string name)
        {
            string lower = name.ToLowerInvariant();
            return lower.Contains("game") || lower.Contains("steam") || lower.Contains("spire");
        }

        // Each drive is searched at the same time, so a slow or crowded drive cannot use up another's time.
        public static List<FoundGame> Drives()
        {
            var found = new List<FoundGame>();
            var clock = Stopwatch.StartNew();
            Parallel.ForEach(FixedDrives(), drive =>
            {
                List<FoundGame> onDrive = SearchDrive(drive, clock);
                lock (found) { foreach (FoundGame game in onDrive) { Add(found, game.Folder, game.Source); } }
            });
            return found;
        }

        // Looks through the top few levels, shallowest folders first, until the time limit. This looks for the game's
        // files rather than its name, so a renamed folder is found too. It stops at the first level with a match,
        // because a game's backups and copies usually sit deeper.
        static List<FoundGame> SearchDrive(string drive, Stopwatch clock)
        {
            var found = new List<FoundGame>();
            var level = new List<string> { drive };
            for (int depth = 0; depth <= MaxDepth && level.Count > 0 && found.Count == 0; depth++)
            {
                var next = new List<string>();
                foreach (string folder in level.OrderByDescending(f => LooksPromising(Path.GetFileName(f))))
                {
                    if (clock.Elapsed > DriveSearchLimit) { return found; }
                    Add(found, folder, "Found by searching");
                    try
                    {
                        // Going through DirectoryInfo gets each folder's attributes without a separate request for each.
                        foreach (DirectoryInfo child in new DirectoryInfo(folder).EnumerateDirectories())
                        {
                            bool linked = (child.Attributes & FileAttributes.ReparsePoint) != 0;
                            bool backup = child.Name.StartsWith("_") || child.Name.IndexOf("backup", StringComparison.OrdinalIgnoreCase) >= 0;
                            if (!linked && !backup && !FoldersNotWorthSearching.Contains(child.Name)) { next.Add(child.FullName); }
                        }
                    }
                    catch (Exception)
                    {
                        // Many system folders refuse to be listed.
                    }
                }
                level = next;
            }
            return found;
        }

        // Turns what someone chose into the game's folder, forgiving a choice inside it or just above it.
        public static string ResolveChoice(string choice)
        {
            if (string.IsNullOrWhiteSpace(choice)) { return null; }
            try
            {
                string start = Path.GetFullPath(choice.Trim().Trim('"'));
                if (File.Exists(start)) { start = Path.GetDirectoryName(start); }
                for (string folder = start; !string.IsNullOrEmpty(folder); folder = Path.GetDirectoryName(folder))
                {
                    if (new GameFolder(folder).LooksLikeTheGame) { return folder.TrimEnd('\\'); }
                }
                string[] below = { GameName, Path.Combine("steamapps", "common", GameName), Path.Combine("common", GameName) };
                foreach (string path in below.Select(b => Path.Combine(start, b)).Concat(Directory.Exists(start) ? Directory.GetDirectories(start) : new string[0]))
                {
                    if (new GameFolder(path).LooksLikeTheGame) { return path.TrimEnd('\\'); }
                }
            }
            catch (Exception)
            {
                // Anything unreadable counts as not being the game.
            }
            return null;
        }
    }
}
