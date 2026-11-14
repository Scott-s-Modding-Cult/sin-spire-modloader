// Installs and updates mods from the zips in this repository's mods folder. What there is comes from docs\mods\mods.json
// on main, the list the mod browser shows: each mod's version, zip, size and SHA-256, and whether it is a preset.
// The Mod Manager's Get Mods tab lists them and compares versions; the patch installs the presets once (InstallPresets),
// so removing a mod from mods.json is all it takes to stop giving it out, and nothing installed is ever overwritten.
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace SinSpireModLoader
{
    class RepoMod
    {
        public string Name, Title, Version, Url, Sha256;
        public long Size;
        public bool Preset;
    }

    static class Importer
    {
        // Plain files, not GitHub's API, which allows few requests without signing in.
        const string Raw = "https://raw.githubusercontent.com/Scott-s-Modding-Cult/sin-spire-modloader/main/";
        const string ListUrl = Raw + "docs/mods/mods.json";
        const string ZipUrl = Raw + "mods/";
        // For tests: another mods.json and another folder for the zips (file:// addresses work).
        const string ListVariable = "SINSPIRE_MODLOADER_TEST_MODS";
        const string ZipVariable = "SINSPIRE_MODLOADER_TEST_ZIPS";

        // Each player's own files, which an update keeps. Everything else in the old folder is replaced.
        static readonly string[] PersonalFiles = { "settings.txt", "monitor.txt", "monitors.txt", "helper.log", "mod-randomizer.json", "boss-timer.txt" };
        static readonly Regex ZipName = new Regex(@"^[A-Za-z0-9_-]+\.zip$");

        static string ImportDir(GameFolder game) { return Path.Combine(game.State, "import"); }
        static string BackupDir(GameFolder game) { return Path.Combine(game.State, "backup"); }
        // The presets the patch has given this game, installed or not, so one the player removed is not put back.
        static string PresetRecord(GameFolder game) { return Path.Combine(game.State, "presets.txt"); }

        static WebClient NewClient()
        {
            // Older Windows setups do not offer TLS 1.2 by default, and GitHub accepts nothing older.
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            var client = new WebClient { Encoding = Encoding.UTF8 };
            client.Headers[HttpRequestHeader.UserAgent] = "SinSpireModLoader"; // GitHub refuses requests without one.
            return client;
        }

        static object Value(Dictionary<string, object> data, string key) { object value; return data.TryGetValue(key, out value) ? value : null; }
        static string Text(Dictionary<string, object> data, string key) { return Value(data, key) as string ?? ""; }

        // Every mod in mods.json that has a zip and a checksum.
        public static List<RepoMod> List()
        {
            string text;
            using (WebClient client = NewClient()) { text = client.DownloadString(Environment.GetEnvironmentVariable(ListVariable) ?? ListUrl); }
            var list = new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject(text) as Dictionary<string, object>;
            if (list == null || !(Value(list, "mods") is object[])) { throw new InvalidDataException("The list of mods could not be read."); }
            string zips = Environment.GetEnvironmentVariable(ZipVariable) ?? ZipUrl;
            var mods = new List<RepoMod>();
            foreach (Dictionary<string, object> entry in ((object[])list["mods"]).OfType<Dictionary<string, object>>())
            {
                string file = Text(entry, "zip"), name = Text(entry, "id"), sha = Text(entry, "sha256");
                if (!ZipName.IsMatch(file) || !string.Equals(file, name + ".zip", StringComparison.OrdinalIgnoreCase) || sha.Length != 64) { continue; }
                mods.Add(new RepoMod
                {
                    Name = name,
                    Title = Text(entry, "title") != "" ? Text(entry, "title") : name,
                    Version = Text(entry, "version"),
                    Url = zips + file,
                    Sha256 = sha.ToUpperInvariant(),
                    Size = Convert.ToInt64(Value(entry, "bytes") ?? 0),
                    Preset = true.Equals(Value(entry, "preset")),
                });
            }
            return mods.OrderBy(m => m.Title, StringComparer.OrdinalIgnoreCase).ToList();
        }

        // Compares versions number by number, so 1.10.0 is newer than 1.9.0. Below zero when a is older.
        public static int CompareVersions(string a, string b)
        {
            string[] x = (a ?? "").Split('.', '-', '+'), y = (b ?? "").Split('.', '-', '+');
            for (int i = 0; i < Math.Max(x.Length, y.Length); i++)
            {
                string p = i < x.Length ? x[i] : "0", q = i < y.Length ? y[i] : "0";
                long m, n;
                int order = long.TryParse(p, out m) && long.TryParse(q, out n) ? m.CompareTo(n) : string.CompareOrdinal(p, q);
                if (order != 0) { return Math.Sign(order); }
            }
            return 0;
        }

        public const string NotInstalled = "Not installed", UpToDate = "Up to date", UpdateAvailable = "Update available", NewerInstalled = "Newer installed";

        // Where the installed copy stands against the listed one. A newer installed copy is never replaced from here.
        public static string Status(RepoMod mod, string installedVersion)
        {
            if (installedVersion == null) { return NotInstalled; }
            int order = CompareVersions(mod.Version, installedVersion);
            return order > 0 ? UpdateAvailable : order == 0 ? UpToDate : NewerInstalled;
        }

        static string Sha256(string path)
        {
            using (Stream stream = File.OpenRead(path))
            using (SHA256 sha = SHA256.Create())
            {
                return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "");
            }
        }

        public static void Install(GameFolder game, RepoMod mod)
        {
            string import = ImportDir(game);
            Directory.CreateDirectory(import);
            string zip = Path.Combine(import, mod.Name + ".zip");
            try
            {
                using (WebClient client = NewClient()) { client.DownloadFile(mod.Url, zip); }
                // Checked against mods.json, so a broken download is caught before anything is replaced.
                if (new FileInfo(zip).Length != mod.Size || Sha256(zip) != mod.Sha256)
                {
                    throw new InvalidDataException("The download of " + mod.Title + " didn't match the mod list. Nothing was changed.");
                }
                InstallZip(game, mod.Name, zip);
            }
            finally
            {
                if (File.Exists(zip)) { File.Delete(zip); }
            }
        }

        // The patch gives each preset in mods.json once: installed if its folder isn't there, then remembered, so a preset the
        // player removed stays removed and an installed copy, older or newer, is left as it is (Get Mods updates it).
        // A game patched by a patch that carried the presets itself (hadBundledPresets) counts every preset as given, so
        // nothing removed comes back.
        // Without the internet it says so and carries on: the loader works, and Get Mods can install them later.
        public static void InstallPresets(GameFolder game, bool hadBundledPresets, Action<string> say)
        {
            List<RepoMod> presets;
            try
            {
                presets = List().Where(m => m.Preset).ToList();
            }
            catch (Exception error)
            {
                say("Could not get the preset mods (" + error.Message + "). The Mod Manager's Get Mods tab can install them later.");
                return;
            }
            string record = PresetRecord(game);
            var given = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (File.Exists(record)) { given.UnionWith(File.ReadAllLines(record).Select(l => l.Trim()).Where(l => l != "")); }
            else if (hadBundledPresets) { given.UnionWith(presets.Select(m => m.Name)); }
            int added = 0;
            foreach (RepoMod mod in presets)
            {
                if (given.Contains(mod.Name)) { continue; }
                if (!Directory.Exists(Path.Combine(game.Mods, mod.Name)))
                {
                    try
                    {
                        Install(game, mod);
                        say("Installed " + mod.Title + " " + mod.Version + ".");
                        added++;
                    }
                    catch (Exception error)
                    {
                        say("Could not install " + mod.Title + ": " + error.Message + " Get Mods can install it later.");
                        continue; // not remembered, so the next patch tries again
                    }
                }
                given.Add(mod.Name);
            }
            Directory.CreateDirectory(game.State);
            File.WriteAllLines(record, given.OrderBy(n => n, StringComparer.OrdinalIgnoreCase));
            say(added > 0 ? "Added " + added + " preset mods to the Mods folder." : "No preset mods to add; the ones you have are left as they are.");
        }

        // Unpacks beside the mods first, so a bad zip leaves the installed mod alone, then swaps the folders.
        public static void InstallZip(GameFolder game, string name, string zip)
        {
            // The launcher's links point into this folder, and the running game has its files open.
            if (game.GameIsRunning()) { throw new InvalidOperationException("Close the game before changing its mods."); }
            string stage = Path.Combine(ImportDir(game), name);
            DeleteFolder(stage);
            try
            {
                Unpack(name, zip, stage);
                string target = Path.Combine(game.Mods, name);
                string backup = Path.Combine(BackupDir(game), name);
                bool replacing = Directory.Exists(target);
                if (replacing)
                {
                    KeepPersonalFiles(target, stage);
                    Directory.CreateDirectory(BackupDir(game));
                    DeleteFolder(backup);
                    Directory.Move(target, backup);
                }
                try
                {
                    Directory.Move(stage, target);
                }
                catch (Exception)
                {
                    if (replacing) { Directory.Move(backup, target); }
                    throw;
                }
            }
            finally
            {
                DeleteFolder(stage);
            }
        }

        static void Unpack(string name, string zip, string stage)
        {
            string root = Path.GetFullPath(stage) + Path.DirectorySeparatorChar;
            string prefix = name + "/";
            using (ZipArchive archive = ZipFile.OpenRead(zip))
            {
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    string path = entry.FullName.Replace('\\', '/');
                    if (!path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new InvalidDataException(name + ".zip holds something outside the " + name + " folder: " + path);
                    }
                    string relative = path.Substring(prefix.Length);
                    if (relative == "" || relative.EndsWith("/")) { continue; }
                    string to = Path.GetFullPath(Path.Combine(stage, relative.Replace('/', Path.DirectorySeparatorChar)));
                    if (!to.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new InvalidDataException(name + ".zip tries to write outside its folder: " + path);
                    }
                    Directory.CreateDirectory(Path.GetDirectoryName(to));
                    entry.ExtractToFile(to, true);
                }
            }
            if (!File.Exists(Path.Combine(stage, "mod.json"))) { throw new InvalidDataException(name + ".zip has no mod.json in its folder."); }
        }

        static void KeepPersonalFiles(string from, string to)
        {
            foreach (string file in Directory.GetFiles(from, "*", SearchOption.AllDirectories))
            {
                if (!PersonalFiles.Contains(Path.GetFileName(file), StringComparer.OrdinalIgnoreCase)) { continue; }
                string path = Path.Combine(to, file.Substring(from.Length).TrimStart(Path.DirectorySeparatorChar));
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                File.Copy(file, path, true);
            }
        }

        static void DeleteFolder(string path)
        {
            if (Directory.Exists(path)) { Directory.Delete(path, true); }
        }
    }
}
