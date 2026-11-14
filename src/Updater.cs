// Keeps the mod loader itself up to date, so players only ever download the patch once. After the game starts, the
// launcher asks GitHub (at most once a day) for the newest full release tagged patch-..., and remembers the answer.
// At the next start, if that release is newer than the installed patch, it offers to update: it downloads the patch,
// checks it against GitHub's size and SHA-256, starts it with --update and exits, and the patch updates the game and
// starts it again.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace SinSpireModLoader
{
    class PatchRelease
    {
        public string Tag, Name, Url, Sha256;
        public long Size;
    }

    static class Updater
    {
        // Every release, newest first. The repository also publishes single mods, so the patch is the newest full
        // release whose tag starts with patch-, whichever release GitHub marks as Latest.
        const string ReleasesUrl = "https://api.github.com/repos/Scott-s-Modding-Cult/sin-spire-modloader/releases?per_page=50";
        public const string PatchAsset = "SinSpire-ModLoader-Patch.exe";
        const string TagPrefix = "patch-";
        // For tests: another releases list (a file:// address works), and an answer to the update question.
        const string ApiVariable = "SINSPIRE_MODLOADER_TEST_API";
        const string AnswerVariable = "SINSPIRE_MODLOADER_TEST_ANSWER";
        static readonly TimeSpan CheckEvery = TimeSpan.FromHours(20);

        static string CacheFile(GameFolder game) { return Path.Combine(game.State, "update.txt"); }
        static string DownloadFolder { get { return Path.Combine(Path.GetTempPath(), "SinSpireModLoader"); } }
        public static string TestAnswer { get { return Environment.GetEnvironmentVariable(AnswerVariable); } }

        static WebClient NewClient()
        {
            // Older Windows setups do not offer TLS 1.2 by default, and GitHub accepts nothing older.
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            var client = new WebClient { Encoding = Encoding.UTF8 };
            client.Headers[HttpRequestHeader.UserAgent] = "SinSpireModLoader"; // GitHub refuses requests without one.
            return client;
        }

        static Dictionary<string, string> ReadKeys(string file)
        {
            var keys = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (!File.Exists(file)) { return keys; }
            foreach (string line in File.ReadAllLines(file))
            {
                int equals = line.IndexOf('=');
                if (equals > 0) { keys[line.Substring(0, equals).Trim()] = line.Substring(equals + 1).Trim(); }
            }
            return keys;
        }

        // The patch release this game was patched with, or null for a patch from before releases were recorded.
        public static string InstalledTag(GameFolder game)
        {
            string tag;
            return ReadKeys(game.InstallInfo).TryGetValue("patch", out tag) && tag != "" ? tag : null;
        }

        // Tags are patch-YYYY.MM.DD, so they sort as text.
        public static bool IsNewer(string latest, string installed)
        {
            return latest != null && (installed == null || string.CompareOrdinal(latest, installed) > 0);
        }

        public static PatchRelease Latest()
        {
            string json;
            using (WebClient client = NewClient()) { json = client.DownloadString(Environment.GetEnvironmentVariable(ApiVariable) ?? ReleasesUrl); }
            object answer = new JavaScriptSerializer().DeserializeObject(json);
            var releases = (answer as object[] ?? new[] { answer }).OfType<Dictionary<string, object>>();
            foreach (Dictionary<string, object> release in releases)
            {
                string tag = Text(release, "tag_name");
                if (true.Equals(Value(release, "draft")) || true.Equals(Value(release, "prerelease")) || !tag.StartsWith(TagPrefix, StringComparison.OrdinalIgnoreCase)) { continue; }
                foreach (var asset in ((Value(release, "assets") as IEnumerable) ?? new object[0]).OfType<Dictionary<string, object>>())
                {
                    if (!string.Equals(Text(asset, "name"), PatchAsset, StringComparison.OrdinalIgnoreCase)) { continue; }
                    string digest = Text(asset, "digest");
                    if (!digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase)) { continue; }
                    return new PatchRelease
                    {
                        Tag = tag,
                        Name = Text(release, "name"),
                        Url = Text(asset, "browser_download_url"),
                        Size = Convert.ToInt64(Value(asset, "size") ?? 0),
                        Sha256 = digest.Substring(7).ToUpperInvariant(),
                    };
                }
            }
            return null;
        }

        static object Value(Dictionary<string, object> data, string key) { object value; return data.TryGetValue(key, out value) ? value : null; }
        static string Text(Dictionary<string, object> data, string key) { return Value(data, key) as string ?? ""; }

        static void Remember(GameFolder game, PatchRelease release)
        {
            Dictionary<string, string> old = ReadKeys(CacheFile(game));
            var lines = new List<string> { "checked=" + DateTime.UtcNow.ToString("o") };
            if (release != null)
            {
                lines.Add("tag=" + release.Tag);
                lines.Add("name=" + release.Name);
                lines.Add("url=" + release.Url);
                lines.Add("size=" + release.Size);
                lines.Add("sha256=" + release.Sha256);
            }
            string skipped;
            if (old.TryGetValue("skip", out skipped)) { lines.Add("skip=" + skipped); }
            Directory.CreateDirectory(game.State);
            File.WriteAllLines(CacheFile(game), lines);
        }

        // Asks GitHub when the last answer is older than a day. Runs after the game has started, so it never delays it.
        public static void RefreshIfDue(GameFolder game)
        {
            try
            {
                // A patch downloaded for an earlier update is no longer running by now.
                string old = Path.Combine(DownloadFolder, PatchAsset);
                if (File.Exists(old)) { File.Delete(old); }
            }
            catch (Exception) { }
            try
            {
                DateTime last;
                string checkedAt;
                if (ReadKeys(CacheFile(game)).TryGetValue("checked", out checkedAt) && DateTime.TryParse(checkedAt, null, System.Globalization.DateTimeStyles.RoundtripKind, out last)
                    && DateTime.UtcNow - last < CheckEvery && Environment.GetEnvironmentVariable(ApiVariable) == null)
                {
                    return;
                }
                Remember(game, Latest());
            }
            catch (Exception error)
            {
                game.Log("Could not check for a mod loader update: " + error.Message);
            }
        }

        // Checks now, for the Mod Manager.
        public static PatchRelease CheckNow(GameFolder game)
        {
            PatchRelease latest = Latest();
            Remember(game, latest);
            return latest;
        }

        // The remembered newer release, unless the player chose to skip it. No internet needed.
        public static PatchRelease Pending(GameFolder game)
        {
            Dictionary<string, string> keys = ReadKeys(CacheFile(game));
            string tag, skip;
            if (!keys.TryGetValue("tag", out tag) || !IsNewer(tag, InstalledTag(game))) { return null; }
            if (keys.TryGetValue("skip", out skip) && skip == tag) { return null; }
            long size;
            long.TryParse(keys.ContainsKey("size") ? keys["size"] : "0", out size);
            return new PatchRelease
            {
                Tag = tag,
                Name = keys.ContainsKey("name") ? keys["name"] : "",
                Url = keys.ContainsKey("url") ? keys["url"] : "",
                Sha256 = keys.ContainsKey("sha256") ? keys["sha256"] : "",
                Size = size,
            };
        }

        public static void Skip(GameFolder game, string tag)
        {
            List<string> lines = File.Exists(CacheFile(game)) ? File.ReadAllLines(CacheFile(game)).Where(l => !l.StartsWith("skip=")).ToList() : new List<string>();
            lines.Add("skip=" + tag);
            File.WriteAllLines(CacheFile(game), lines);
        }

        public static string Megabytes(long bytes) { return (bytes / 1048576.0).ToString("0.0") + " MB"; }

        // Into the temp folder, then checked against GitHub's size and SHA-256 before it is run.
        public static string Download(PatchRelease release, Action<long> progress)
        {
            Directory.CreateDirectory(DownloadFolder);
            string path = Path.Combine(DownloadFolder, PatchAsset);
            if (File.Exists(path)) { File.Delete(path); }
            using (WebClient client = NewClient())
            {
                client.DownloadProgressChanged += (s, e) => progress(e.BytesReceived);
                try { client.DownloadFileTaskAsync(new Uri(release.Url), path).Wait(); }
                catch (AggregateException error) { throw error.InnerException; }
            }
            string sha;
            using (var stream = File.OpenRead(path))
            using (var hash = SHA256.Create())
            {
                sha = BitConverter.ToString(hash.ComputeHash(stream)).Replace("-", "");
            }
            if (new FileInfo(path).Length != release.Size || sha != release.Sha256)
            {
                File.Delete(path);
                throw new IOException("The download didn't match what GitHub lists for it, so it was deleted unused.");
            }
            return path;
        }

        // The patch waits for this program to close, updates the game, and starts SinSpire.exe again with these arguments.
        public static void StartUpdate(GameFolder game, string patch, string thenArguments)
        {
            string arguments = "--update \"" + game.Root.TrimEnd('\\') + "\" --wait " + Process.GetCurrentProcess().Id;
            if (thenArguments != "") { arguments += " --then \"" + thenArguments.Replace("\"", "'") + "\""; }
            Process.Start(new ProcessStartInfo(patch, arguments) { UseShellExecute = false });
        }

        // Downloads with a small progress window, then hands over to the patch. True when the update has started.
        public static bool DownloadAndStart(GameFolder game, PatchRelease release, string thenArguments, IWin32Window owner)
        {
            using (var form = new ProgressForm("Updating the Sin Spire Mod Loader", "Downloading " + release.Tag + "..."))
            {
                string patch = null;
                Exception failure = null;
                form.Shown += async (s, e) =>
                {
                    try
                    {
                        patch = await Task.Run(() => Download(release, received =>
                            form.Say("Downloading " + release.Tag + ": " + Megabytes(received) + " of " + Megabytes(release.Size) + "...")));
                    }
                    catch (Exception error) { failure = error; }
                    form.Close();
                };
                // Before the game starts there is no window yet: then it runs on its own, without taking the focus.
                if (owner == null) { Application.Run(form); } else { form.ShowDialog(owner); }
                if (failure != null || patch == null)
                {
                    string why = failure != null ? failure.Message : "The download was stopped.";
                    game.Log("Mod loader update failed: " + why);
                    MessageBox.Show(owner, "The update could not be downloaded: " + why + "\n\nThe game starts with the mod loader you have.",
                        "Sin Spire mods", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return false;
                }
                game.Log("Downloaded mod loader " + release.Tag + "; starting the update.");
                StartUpdate(game, patch, thenArguments);
                return true;
            }
        }
    }

    enum UpdateChoice { Update, Later, Skip }

    class UpdatePrompt : Form
    {
        public UpdateChoice Choice = UpdateChoice.Later;

        public UpdatePrompt(PatchRelease release, string installed)
        {
            Text = "Sin Spire mods";
            AutoScaleDimensions = new SizeF(96F, 96F);
            AutoScaleMode = AutoScaleMode.Dpi;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            AutoSize = true;
            AutoSizeMode = AutoSizeMode.GrowAndShrink;
            var message = new Label
            {
                AutoSize = true,
                MaximumSize = new Size(440, 0),
                Padding = new Padding(0, 0, 0, 10),
                Text = "A new version of the Sin Spire Mod Loader is out: " + release.Tag + (release.Name != "" ? " (" + release.Name + ")" : "") + ".\n" +
                       "You have " + (installed ?? "an older one") + ".\n\n" +
                       "Update downloads it (" + Updater.Megabytes(release.Size) + "), updates the loader and then starts the game. " +
                       "Your mods, their settings and your saves stay as they are.",
            };
            var update = new Button { Text = "Update", AutoSize = true, DialogResult = DialogResult.OK };
            var later = new Button { Text = "Not Now", AutoSize = true, DialogResult = DialogResult.Cancel };
            var skip = new Button { Text = "Skip This Version", AutoSize = true, DialogResult = DialogResult.Ignore };
            update.Click += (s, e) => Choice = UpdateChoice.Update;
            var tips = new ToolTip { AutoPopDelay = 20000, InitialDelay = 400 };
            tips.SetToolTip(update, "Download and install this version now, then start the game.");
            tips.SetToolTip(skip, "Don't ask about this version again. You're asked again when a newer one comes out.");
            tips.SetToolTip(later, "Start the game now with the loader you have. You're asked again next time.");
            skip.Click += (s, e) => Choice = UpdateChoice.Skip;
            var buttons = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft };
            buttons.Controls.AddRange(new Control[] { later, skip, update });
            var layout = new TableLayoutPanel { AutoSize = true, ColumnCount = 1, Padding = new Padding(12) };
            layout.Controls.Add(message);
            layout.Controls.Add(buttons);
            Controls.Add(layout);
            AcceptButton = update;
            CancelButton = later;
        }

        public static UpdateChoice Ask(PatchRelease release, string installed)
        {
            string answer = Updater.TestAnswer;
            if (answer == "update") { return UpdateChoice.Update; }
            if (answer == "skip") { return UpdateChoice.Skip; }
            if (answer == "later") { return UpdateChoice.Later; }
            using (var prompt = new UpdatePrompt(release, installed))
            {
                prompt.ShowDialog();
                return prompt.Choice;
            }
        }
    }

    // A small window that shows what is happening without taking the focus.
    class ProgressForm : Form
    {
        readonly Label label = new Label { AutoSize = true, MaximumSize = new Size(420, 0), Padding = new Padding(16) };

        public ProgressForm(string title, string text)
        {
            Text = title;
            AutoScaleDimensions = new SizeF(96F, 96F);
            AutoScaleMode = AutoScaleMode.Dpi;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = MinimizeBox = ControlBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(440, 80);
            label.Text = text;
            Controls.Add(label);
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        public void Say(string text)
        {
            if (IsDisposed) { return; }
            if (InvokeRequired) { BeginInvoke(new Action<string>(Say), text); return; }
            label.Text = text;
        }
    }
}
