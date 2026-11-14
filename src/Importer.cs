// Installs and updates mods from the zips in this repository's mods folder, for the Mod Manager's Get Mods tab.
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
        public string Name, Sha, Url;
        public long Size;
    }

    static class Importer
    {
        const string ListUrl = "https://api.github.com/repos/Scott-s-Modding-Cult/sin-spire-modloader/contents/mods?ref=main";

        // Each player's own files, which an update keeps. Everything else in the old folder is replaced.
        static readonly string[] PersonalFiles = { "settings.txt", "monitor.txt", "monitors.txt", "helper.log", "mod-randomizer.json", "boss-timer.txt" };
        static readonly Regex ZipName = new Regex(@"^[A-Za-z0-9_-]+\.zip$");

        static string ImportDir(GameFolder game) { return Path.Combine(game.State, "import"); }
        static string BackupDir(GameFolder game) { return Path.Combine(game.State, "backup"); }
        static string RecordFile(GameFolder game) { return Path.Combine(game.State, "imports.txt"); }

        static WebClient NewClient()
        {
            // Older Windows setups do not offer TLS 1.2 by default, and GitHub accepts nothing older.
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            var client = new WebClient { Encoding = Encoding.UTF8 };
            client.Headers[HttpRequestHeader.UserAgent] = "SinSpireModLoader"; // GitHub refuses requests without one.
            return client;
        }

        public static List<RepoMod> List()
        {
            string text;
            using (WebClient client = NewClient()) { text = client.DownloadString(ListUrl); }
            var mods = new List<RepoMod>();
            foreach (Dictionary<string, object> entry in new JavaScriptSerializer().Deserialize<List<Dictionary<string, object>>>(text))
            {
                string file = (string)entry["name"];
                if ((string)entry["type"] != "file" || !ZipName.IsMatch(file)) { continue; }
                mods.Add(new RepoMod
                {
                    Name = Path.GetFileNameWithoutExtension(file),
                    Sha = (string)entry["sha"],
                    Url = (string)entry["download_url"],
                    Size = Convert.ToInt64(entry["size"]),
                });
            }
            return mods.OrderBy(m => m.Name, StringComparer.OrdinalIgnoreCase).ToList();
        }

        // Which download each mod came from. Presets from the patch are not listed, so their age is unknown.
        public static Dictionary<string, string> Recorded(GameFolder game)
        {
            var recorded = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (File.Exists(RecordFile(game)))
            {
                foreach (string line in File.ReadAllLines(RecordFile(game)))
                {
                    int equals = line.IndexOf('=');
                    if (equals > 0) { recorded[line.Substring(0, equals)] = line.Substring(equals + 1); }
                }
            }
            return recorded;
        }

        // The hash GitHub lists for a file, so a broken download is caught before anything is replaced.
        public static string BlobSha(string path)
        {
            byte[] data = File.ReadAllBytes(path);
            byte[] header = Encoding.ASCII.GetBytes("blob " + data.Length + "\0");
            using (SHA1 sha = SHA1.Create())
            {
                sha.TransformBlock(header, 0, header.Length, null, 0);
                sha.TransformFinalBlock(data, 0, data.Length);
                return string.Concat(sha.Hash.Select(b => b.ToString("x2")));
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
                if (BlobSha(zip) != mod.Sha) { throw new InvalidDataException("The download of " + mod.Name + " was damaged. Nothing was changed."); }
                InstallZip(game, mod.Name, zip);
                Dictionary<string, string> recorded = Recorded(game);
                recorded[mod.Name] = mod.Sha;
                File.WriteAllLines(RecordFile(game), recorded.Select(p => p.Key + "=" + p.Value));
            }
            finally
            {
                File.Delete(zip);
            }
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
