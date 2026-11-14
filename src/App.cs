// Sin Spire Mod Manager: one program for everything. Where it runs decides what it does:
//   - In a game folder as SinSpire.exe it is the launcher: it puts the enabled mods in place and starts the game
//     (hold Shift, or pass -modmanager, to get the Mod Manager first). Installing the mod loader copies this program there.
//   - Anywhere else (the download) it is the Mod Manager app: the Mod Loader tab installs, updates, repairs and removes
//     the loader, and the Mods and Get Mods tabs manage the mods.
// Without a window, for scripts, tests and older versions:
//   --patch "<game>" | --unpatch "<game>"               install or remove the loader; exit code 0 when it worked
//   --update "<game>" --wait <pid> [--then "<args>"] [--app "<path>"]
//                                    run by an older copy that downloaded this one: waits for it to close, updates the game,
//                                    puts this program in place of the app at <path> when given, then starts it again
//   --handover install|remove "<game>" --wait <pid> [--shortcut]
//                                    the copy in the game folder can't replace or delete itself, so it hands the work to a
//                                    copy of itself in the temp folder
//   --find "<file>" [<choice>...]    writes what the game search finds, for tests
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace SinSpireModLoader
{
    static class App
    {
        public const string Name = "Sin Spire Mod Manager";
        // For tests: don't start the game or the app again after an update or a handover; write what would start instead.
        const string NoStartVariable = "SINSPIRE_MODLOADER_TEST_NO_START";

        [DllImport("user32.dll")]
        static extern bool SetProcessDPIAware();

        // This program's own file, also when another process has loaded it (as the tests do).
        public static string Self { get { return Path.GetFullPath(typeof(App).Assembly.Location); } }

        static string Arg(string[] args, string name)
        {
            int at = Array.IndexOf(args, name);
            return at >= 0 && at + 1 < args.Length ? args[at + 1] : null;
        }

        [STAThread]
        static int Main(string[] args)
        {
            // Without this, Windows reports scaled positions on monitors that are not at 100%.
            SetProcessDPIAware();
            string mode = args.Length > 0 ? args[0] : "";
            if (args.Length == 2 && (mode == "--patch" || mode == "--unpatch")) { return Silent(new GameFolder(args[1]), mode == "--patch"); }
            if (args.Length >= 2 && mode == "--update")
            {
                return Update(args[1] == "" ? null : new GameFolder(args[1]), Arg(args, "--wait"), Arg(args, "--then"), Arg(args, "--app"));
            }
            if (args.Length >= 3 && mode == "--handover") { return Handover(args[1], new GameFolder(args[2]), Arg(args, "--wait"), args.Contains("--shortcut")); }
            if (args.Length >= 2 && mode == "--find")
            {
                var lines = GameSearch.Quick().Select(f => "quick|" + f.Source + "|" + f.Folder).ToList();
                lines.AddRange(GameSearch.Drives().Select(f => "drives|" + f.Source + "|" + f.Folder));
                foreach (string choice in args.Skip(2)) { lines.Add("choice|" + choice + "|" + GameSearch.ResolveChoice(choice)); }
                File.WriteAllLines(args[1], lines);
                return 0;
            }

            Application.EnableVisualStyles();
            var here = new GameFolder(Path.GetDirectoryName(Self));
            if (string.Equals(Self, here.Exe, StringComparison.OrdinalIgnoreCase) && here.LooksLikeTheGame)
            {
                Launcher.Run(here, args);
                return 0;
            }
            // The app: the game it last worked on, or the first one the quick search finds (the tab can change it).
            string remembered = Settings.Get("game");
            GameFolder game = remembered != null && new GameFolder(remembered).LooksLikeTheGame ? new GameFolder(remembered) : null;
            if (game == null)
            {
                FoundGame found = GameSearch.Quick().FirstOrDefault();
                if (found != null) { game = new GameFolder(found.Folder); }
            }
            var manager = new ManagerForm(game, true);
            Application.Run(manager);
            if (manager.Play && manager.Game != null) { StartProgram(manager.Game.Exe, "", manager.Game.Root); }
            return 0;
        }

        static int Silent(GameFolder game, bool install)
        {
            var report = new List<string>();
            try
            {
                if (install) { Patch.Apply(game, report.Add); } else { Patch.Remove(game, report.Add); }
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

        // Starts a program, or for tests only writes down what would start.
        public static void StartProgram(string exe, string arguments, string folder)
        {
            string note = Environment.GetEnvironmentVariable(NoStartVariable);
            if (!string.IsNullOrEmpty(note))
            {
                File.AppendAllText(note, exe + " " + arguments + Environment.NewLine);
                return;
            }
            Process.Start(new ProcessStartInfo(exe, arguments) { WorkingDirectory = folder, UseShellExecute = false });
        }

        static void WaitFor(string id)
        {
            int pid;
            if (!int.TryParse(id, out pid) || pid <= 0) { return; }
            try { using (Process other = Process.GetProcessById(pid)) { other.WaitForExit(30000); } }
            catch (ArgumentException) { } // already gone
        }

        // Runs the work with a small window showing each step. Returns the failure, or null.
        static Exception WithProgress(string title, Action<Action<string>> work, List<string> report)
        {
            Exception failure = null;
            using (var form = new ProgressForm(title, title + "..."))
            {
                form.Shown += async (s, e) =>
                {
                    try { await Task.Run(() => work(line => { report.Add(line); form.Say(line); })); }
                    catch (Exception error) { failure = error; }
                    form.Close();
                };
                Application.Run(form);
            }
            if (failure != null) { report.Add("Failed: " + failure); }
            return failure;
        }

        // Its own log, as every start of the game begins modloader.log afresh.
        static string WriteLog(GameFolder game, List<string> report)
        {
            if (game == null) { return null; }
            string log = Path.Combine(game.State, "update.log");
            try
            {
                Directory.CreateDirectory(game.State);
                File.AppendAllLines(log, report.Select(line => DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + line));
            }
            catch (Exception) { }
            return log;
        }

        // A copy can't be replaced while it runs, so the old one starts this new one and closes; this waits for it, updates
        // the game (whose SinSpire.exe becomes this program) and the app the player opened, and starts the right one again.
        static int Update(GameFolder game, string waitFor, string thenArguments, string appPath)
        {
            WaitFor(waitFor);
            Application.EnableVisualStyles();
            string version = Patch.Tag ?? "a new version";
            var report = new List<string> { "Updating to " + version + "." };
            Exception failure = WithProgress("Updating the " + Name + " to " + version, say =>
            {
                if (game != null && game.LooksLikeTheGame) { Patch.Apply(game, say); }
                if (appPath != null) { ReplaceApp(appPath, say); }
            }, report);
            string log = WriteLog(game, report);
            if (failure != null)
            {
                MessageBox.Show("The update didn't finish: " + failure.Message + (log != null ? "\n\nThe log is " + log + "." : "") +
                    "\n\nYou can also download the " + Name + " again from its releases page.", Name, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            // Started either way: after a failure the old copy is still in place.
            if (appPath != null) { StartProgram(appPath, "", Path.GetDirectoryName(appPath)); }
            else if (game != null) { StartProgram(game.Exe, (thenArguments ?? "").Replace("'", "\""), game.Root); }
            return failure == null ? 0 : 1;
        }

        // Puts this program in place of the app the player opened. The old one has just closed, so its file may stay
        // locked for a moment.
        static void ReplaceApp(string appPath, Action<string> say)
        {
            if (string.Equals(Path.GetFullPath(appPath), Self, StringComparison.OrdinalIgnoreCase)) { return; }
            for (int attempt = 1; ; attempt++)
            {
                try
                {
                    File.Copy(Self, appPath, true);
                    say("Updated " + Path.GetFileName(appPath) + ".");
                    return;
                }
                catch (Exception error)
                {
                    if (attempt >= 20 || !(error is IOException || error is UnauthorizedAccessException)) { throw; }
                    Thread.Sleep(500);
                }
            }
        }

        // The Mod Manager opened from the game folder is the game's SinSpire.exe, which installing replaces and removing
        // deletes. So it copies itself to the temp folder, starts that copy with the job, and closes.
        public static void HandOver(string job, GameFolder game, bool shortcut)
        {
            string folder = Path.Combine(Path.GetTempPath(), "SinSpireModLoader");
            Directory.CreateDirectory(folder);
            string copy = Path.Combine(folder, "SinSpire-ModManager-handover.exe");
            File.Copy(Self, copy, true);
            string arguments = "--handover " + job + " \"" + game.Root + "\" --wait " + Process.GetCurrentProcess().Id + (shortcut ? " --shortcut" : "");
            Process.Start(new ProcessStartInfo(copy, arguments) { UseShellExecute = false });
        }

        static int Handover(string job, GameFolder game, string waitFor, bool shortcut)
        {
            WaitFor(waitFor);
            Application.EnableVisualStyles();
            bool install = job == "install";
            var report = new List<string>();
            Exception failure = WithProgress(install ? "Installing the mod loader" : "Removing the mod loader", say =>
            {
                if (install) { Patch.Apply(game, say); if (shortcut) { Shortcut.Create(game, say); } }
                else { Patch.Remove(game, say); Shortcut.Remove(game, say); }
            }, report);
            string log = WriteLog(game, report);
            if (failure != null)
            {
                MessageBox.Show("That didn't finish: " + failure.Message + "\n\nThe log is " + log + ".", Name, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            if (install || failure != null) { StartProgram(game.Exe, "-modmanager", game.Root); }
            else if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable(NoStartVariable)))
            {
                MessageBox.Show("The mod loader is removed. Your Mods folder is kept.\n\nTo install it again, open the " + Name +
                    " you downloaded.", Name, MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            return failure == null ? 0 : 1;
        }
    }

    // What the app remembers between runs, in the player's local app data.
    static class Settings
    {
        static string File { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SinSpireModManager", "settings.txt"); } }

        public static string Get(string key)
        {
            try
            {
                if (!System.IO.File.Exists(File)) { return null; }
                string line = System.IO.File.ReadAllLines(File).FirstOrDefault(l => l.StartsWith(key + "="));
                return line == null ? null : line.Substring(key.Length + 1);
            }
            catch (Exception) { return null; }
        }

        public static void Set(string key, string value)
        {
            try
            {
                var lines = System.IO.File.Exists(File) ? System.IO.File.ReadAllLines(File).Where(l => !l.StartsWith(key + "=")).ToList() : new List<string>();
                lines.Add(key + "=" + value);
                Directory.CreateDirectory(Path.GetDirectoryName(File));
                System.IO.File.WriteAllLines(File, lines);
            }
            catch (Exception) { }
        }
    }

    // A Start menu entry that opens the Mod Manager through the game's own copy, so the player always finds it.
    static class Shortcut
    {
        // For tests: another folder than the Start menu.
        const string FolderVariable = "SINSPIRE_MODLOADER_TEST_SHORTCUTS";

        static string Path_
        {
            get
            {
                string folder = Environment.GetEnvironmentVariable(FolderVariable);
                if (string.IsNullOrEmpty(folder)) { folder = Environment.GetFolderPath(Environment.SpecialFolder.Programs); }
                return Path.Combine(folder, App.Name + ".lnk");
            }
        }

        public static bool Exists { get { return File.Exists(Path_); } }

        public static void Create(GameFolder game, Action<string> say)
        {
            try
            {
                Type shellType = Type.GetTypeFromProgID("WScript.Shell");
                dynamic shell = Activator.CreateInstance(shellType);
                dynamic link = shell.CreateShortcut(Path_);
                link.TargetPath = game.Exe;
                link.Arguments = "-modmanager";
                link.WorkingDirectory = game.Root;
                link.IconLocation = game.Exe + ",0";
                link.Description = "Turn Sin Spire mods on and off, get new ones, and keep the mod loader up to date.";
                link.Save();
                Marshal.FinalReleaseComObject(link);
                Marshal.FinalReleaseComObject(shell);
                say("Added " + App.Name + " to the Start menu.");
            }
            catch (Exception error)
            {
                say("Couldn't add the Start menu entry: " + error.Message);
            }
        }

        // Only the entry that points at this game.
        public static void Remove(GameFolder game, Action<string> say)
        {
            try
            {
                if (!Exists) { return; }
                Type shellType = Type.GetTypeFromProgID("WScript.Shell");
                dynamic shell = Activator.CreateInstance(shellType);
                dynamic link = shell.CreateShortcut(Path_);
                string target = link.TargetPath;
                Marshal.FinalReleaseComObject(link);
                Marshal.FinalReleaseComObject(shell);
                if (!string.Equals(target, game.Exe, StringComparison.OrdinalIgnoreCase)) { return; }
                File.Delete(Path_);
                say("Removed " + App.Name + " from the Start menu.");
            }
            catch (Exception error)
            {
                say("Couldn't remove the Start menu entry: " + error.Message);
            }
        }
    }
}
