// Takes the place of SinSpire.exe. Puts the enabled mods in place, then starts the original game with the saved
// monitor's position, because -WinX and -WinY are the only way to make the first frame open on that monitor.
// Hold Shift while starting it, or pass -modmanager, to get the mod list first.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;

[assembly: AssemblyProduct("SinSpire Mod Loader")]
[assembly: AssemblyTitle("Sin Spire")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace SinSpireModLoader
{
    static class Launcher
    {
        const string ManagerArgument = "-modmanager";
        const string MonitorFile = @"SinSpire\Binaries\Win64\ue4ss\Mods\MonitorSetting\monitor.txt";

        [DllImport("user32.dll")]
        static extern bool SetProcessDPIAware();

        // Windows numbers each display in its device name, such as \\.\DISPLAY2.
        static int DisplayNumber(Screen screen)
        {
            int number;
            return int.TryParse(Regex.Replace(screen.DeviceName, @"\D", ""), out number) ? number : 0;
        }

        static string PositionArguments(string folder)
        {
            try
            {
                int wanted = int.Parse(File.ReadLines(Path.Combine(folder, MonitorFile)).First().Trim());
                Screen screen = Screen.AllScreens.FirstOrDefault(s => DisplayNumber(s) == wanted);
                if (screen != null)
                {
                    return string.Format("-WinX={0} -WinY={1}", screen.Bounds.X, screen.Bounds.Y);
                }
            }
            catch (Exception)
            {
                // With no usable setting the game simply opens where it normally would.
            }
            return "";
        }

        // Everything after this program's own name, so arguments from a shortcut or launcher still reach the game.
        static string PassedArguments()
        {
            string line = Environment.CommandLine;
            int end = line.StartsWith("\"") ? line.IndexOf('"', 1) + 1 : line.IndexOf(' ');
            string passed = end <= 0 || end >= line.Length ? "" : line.Substring(end).Trim();
            return Regex.Replace(passed, Regex.Escape(ManagerArgument) + @"\b", "", RegexOptions.IgnoreCase).Trim();
        }

        static void StartGame(GameFolder game)
        {
            var start = new ProcessStartInfo(game.OriginalExe)
            {
                Arguments = (PositionArguments(game.Root) + " " + PassedArguments()).Trim(),
                WorkingDirectory = game.Root,
                UseShellExecute = false,
            };
            Process.Start(start);
        }

        [STAThread]
        static void Main(string[] args)
        {
            // Without this, Windows reports scaled positions on monitors that are not at 100%.
            SetProcessDPIAware();
            Application.EnableVisualStyles();
            var game = new GameFolder(AppDomain.CurrentDomain.BaseDirectory);

            bool wantsManager = (Control.ModifierKeys & Keys.Shift) != 0
                || args.Any(a => a.Equals(ManagerArgument, StringComparison.OrdinalIgnoreCase));
            if (wantsManager)
            {
                var manager = new ManagerForm(game);
                Application.Run(manager);
                if (!manager.Play) { return; }
            }
            else if (OfferUpdate(game))
            {
                return; // The patch updates the game and starts it again.
            }

            // Whatever goes wrong with the mods, the game itself should still start.
            try
            {
                List<Problem> problems = Deployer.Deploy(game);
                string[] serious = problems.Where(p => p.Serious).Select(p => p.Text).ToArray();
                if (serious.Length > 0)
                {
                    MessageBox.Show(string.Join("\n\n", serious) + "\n\nThe game will start without those mods.",
                        "Sin Spire mods", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
            }
            catch (Exception error)
            {
                game.Log("Could not set up the mods: " + error);
                MessageBox.Show("The mods could not be set up, so some may be missing.\n\n" + error.Message,
                    "Sin Spire mods", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            StartGame(game);
            // The game is on its way, so this costs it nothing. The answer is used at the next start.
            Updater.RefreshIfDue(game);
        }

        // A newer mod loader found at an earlier start: update now, later, or never for that version.
        static bool OfferUpdate(GameFolder game)
        {
            try
            {
                PatchRelease release = Updater.Pending(game);
                if (release == null) { return false; }
                UpdateChoice choice = UpdatePrompt.Ask(release, Updater.InstalledTag(game));
                if (choice == UpdateChoice.Skip) { Updater.Skip(game, release.Tag); }
                return choice == UpdateChoice.Update && Updater.DownloadAndStart(game, release, PassedArguments(), null);
            }
            catch (Exception error)
            {
                game.Log("Could not offer the mod loader update: " + error);
                return false;
            }
        }
    }

    class ManagerForm : Form
    {
        readonly GameFolder game;
        readonly List<ModInfo> mods;
        readonly CheckedListBox list = new CheckedListBox { Dock = DockStyle.Fill, CheckOnClick = true, IntegralHeight = false };
        readonly TextBox details = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical };
        readonly TextBox warnings = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical };
        readonly ListView repoList = new ListView { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, MultiSelect = false, HideSelection = false };
        readonly Label repoStatus = new Label { Dock = DockStyle.Fill, AutoSize = true, Padding = new Padding(0, 6, 0, 6) };
        readonly Button install = new Button { Text = "Install", AutoSize = true, Enabled = false };
        readonly Button recheck = new Button { Text = "Check Again", AutoSize = true };
        readonly Button play = new Button { Text = "Save and Play", AutoSize = true };
        readonly Button close = new Button { Text = "Save and Close", AutoSize = true };
        readonly Label loaderStatus = new Label { AutoSize = true, Anchor = AnchorStyles.Left, Padding = new Padding(0, 6, 0, 6) };
        readonly Button updateLoader = new Button { Text = "Update Mod Loader", AutoSize = true, Visible = false };
        PatchRelease loaderRelease;
        List<RepoMod> repoMods = new List<RepoMod>();
        bool repoChecked, busy;
        bool filling;

        public bool Play { get; private set; }

        public ManagerForm(GameFolder game)
        {
            this.game = game;
            mods = Registry.Load(game);
            Text = "Sin Spire Mods";
            AutoScaleDimensions = new SizeF(96F, 96F);
            AutoScaleMode = AutoScaleMode.Dpi;
            ClientSize = new Size(760, 500);
            MinimumSize = new Size(560, 380);
            StartPosition = FormStartPosition.CenterScreen;
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); }
            catch (Exception) { }

            var up = new Button { Text = "Move Up", AutoSize = true };
            var down = new Button { Text = "Move Down", AutoSize = true };
            var folder = new Button { Text = "Open Mods Folder", AutoSize = true };
            up.Click += (s, e) => MoveSelected(-1);
            down.Click += (s, e) => MoveSelected(1);
            folder.Click += (s, e) => { Directory.CreateDirectory(game.Mods); Process.Start(game.Mods); };
            play.Click += (s, e) => { Registry.Save(game, mods); Play = true; Close(); };
            close.Click += (s, e) => { Registry.Save(game, mods); Close(); };
            list.ItemCheck += ListItemCheck;
            list.SelectedIndexChanged += (s, e) => ShowDetails();

            var left = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true };
            left.Controls.AddRange(new Control[] { up, down, folder });
            var right = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, FlowDirection = FlowDirection.RightToLeft };
            right.Controls.AddRange(new Control[] { play, close });

            var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 3, Padding = new Padding(8) };
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 72F));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 28F));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.Controls.Add(list, 0, 0);
            layout.Controls.Add(details, 1, 0);
            layout.Controls.Add(warnings, 0, 1);
            layout.SetColumnSpan(warnings, 2);
            layout.Controls.Add(left, 0, 2);
            layout.SetColumnSpan(left, 2);

            var tabs = new TabControl { Dock = DockStyle.Fill };
            var modsTab = new TabPage("Mods");
            modsTab.Controls.Add(layout);
            var repoTab = new TabPage("Get Mods");
            repoTab.Controls.Add(BuildRepoPage());
            tabs.TabPages.AddRange(new[] { modsTab, repoTab });
            // The list comes from the internet, so it waits until someone asks for this tab.
            tabs.SelectedIndexChanged += (s, e) => { if (tabs.SelectedTab == repoTab && !repoChecked) { CheckRepo(); } };

            var outer = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2 };
            outer.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            outer.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            outer.Controls.Add(tabs, 0, 0);
            outer.Controls.Add(right, 0, 1);
            Controls.Add(outer);
            // A swap of a mod's folders must not be cut short.
            FormClosing += (s, e) => { if (busy) { e.Cancel = true; } };

            Fill(0);
        }

        Control BuildRepoPage()
        {
            repoList.Columns.Add("Mod", 240);
            repoList.Columns.Add("Installed", 90);
            repoList.Columns.Add("Download", 90);
            repoList.Columns.Add("Status", 150);
            repoList.SelectedIndexChanged += (s, e) => UpdateInstallButton();
            install.Click += (s, e) => InstallSelected();
            recheck.Click += (s, e) => CheckRepo();
            updateLoader.Click += (s, e) => UpdateLoader();
            loaderRelease = Updater.Pending(game); // what the last check found, until this tab checks again
            ShowLoader();

            var note = new Label
            {
                Text = "Installing replaces the mod's folder. Its settings are kept, and the old version is saved in Mods\\.modloader\\backup.",
                Dock = DockStyle.Fill,
                AutoSize = true,
                Padding = new Padding(0, 0, 0, 6),
            };
            var buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true };
            buttons.Controls.AddRange(new Control[] { install, recheck });

            var loader = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, Padding = new Padding(0, 0, 0, 4) };
            loader.Controls.AddRange(new Control[] { loaderStatus, updateLoader });

            var page = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 5, Padding = new Padding(8) };
            page.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            page.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            page.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            page.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            page.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            page.Controls.Add(loader, 0, 0);
            page.Controls.Add(note, 0, 1);
            page.Controls.Add(repoList, 0, 2);
            page.Controls.Add(repoStatus, 0, 3);
            page.Controls.Add(buttons, 0, 4);
            return page;
        }

        void SetBusy(bool value, string message)
        {
            busy = value;
            recheck.Enabled = play.Enabled = close.Enabled = updateLoader.Enabled = !value;
            repoStatus.Text = message;
            UpdateInstallButton();
        }

        async void CheckRepo()
        {
            repoChecked = true;
            SetBusy(true, "Checking for mods...");
            string message;
            try
            {
                repoMods = await Task.Run(() => Importer.List());
                message = repoMods.Count + " mods available.";
            }
            catch (Exception error)
            {
                game.Log("Could not list the mods to download: " + error);
                message = "Could not check for mods: " + error.Message;
            }
            try
            {
                loaderRelease = await Task.Run(() => Updater.CheckNow(game));
            }
            catch (Exception error)
            {
                game.Log("Could not check for a mod loader update: " + error.Message);
            }
            ShowLoader();
            FillRepo();
            SetBusy(false, message);
        }

        void ShowLoader()
        {
            string installed = Updater.InstalledTag(game);
            bool newer = loaderRelease != null && Updater.IsNewer(loaderRelease.Tag, installed);
            loaderStatus.Text = newer
                ? "Mod Loader " + loaderRelease.Tag + " is out. You have " + (installed ?? "an older one") + "."
                : "Mod Loader: " + (installed ?? "a patch from before 2026-11-14") + (loaderRelease != null ? ", up to date." : ".");
            updateLoader.Visible = newer;
        }

        // Saves the list, then the patch updates the game and opens this window again.
        void UpdateLoader()
        {
            if (loaderRelease == null) { return; }
            Registry.Save(game, mods);
            if (Updater.DownloadAndStart(game, loaderRelease, "-modmanager", this)) { Close(); }
        }

        async void InstallSelected()
        {
            if (repoList.SelectedItems.Count == 0) { return; }
            var mod = (RepoMod)repoList.SelectedItems[0].Tag;
            SetBusy(true, "Downloading and installing " + mod.Name + "...");
            string message;
            try
            {
                await Task.Run(() => Importer.Install(game, mod));
                ReloadMods();
                message = mod.Name + " is installed. It takes effect the next time the game starts.";
                game.Log("Installed " + mod.Name + " from the repository, " + mod.Sha);
            }
            catch (Exception error)
            {
                game.Log("Could not install " + mod.Name + ": " + error);
                message = "Could not install " + mod.Name + ": " + error.Message;
            }
            FillRepo();
            SetBusy(false, message);
        }

        // Picks up the new files, keeping the order and the ticks on screen, as those are only saved on Save.
        void ReloadMods()
        {
            List<ModInfo> fresh = Registry.Load(game);
            var kept = new List<ModInfo>();
            foreach (ModInfo old in mods)
            {
                ModInfo match = fresh.FirstOrDefault(m => m.Name.Equals(old.Name, StringComparison.OrdinalIgnoreCase));
                if (match != null)
                {
                    match.Enabled = old.Enabled;
                    kept.Add(match);
                }
            }
            kept.AddRange(fresh.Where(m => !kept.Contains(m)));
            int selected = list.SelectedIndex;
            mods.Clear();
            mods.AddRange(kept);
            Fill(selected);
        }

        static string RepoStatus(RepoMod mod, bool installed, Dictionary<string, string> recorded)
        {
            string sha;
            if (!installed) { return "Not installed"; }
            if (!recorded.TryGetValue(mod.Name, out sha)) { return "Installed"; } // Came with the patch, so its age is unknown.
            return sha == mod.Sha ? "Up to date" : "Update available";
        }

        void FillRepo()
        {
            string selected = repoList.SelectedItems.Count > 0 ? ((RepoMod)repoList.SelectedItems[0].Tag).Name : null;
            Dictionary<string, string> recorded = Importer.Recorded(game);
            repoList.Items.Clear();
            foreach (RepoMod mod in repoMods)
            {
                ModInfo local = mods.FirstOrDefault(m => m.Name.Equals(mod.Name, StringComparison.OrdinalIgnoreCase));
                var item = new ListViewItem(new[]
                {
                    local != null ? local.Title : mod.Name,
                    local != null ? local.Version : "",
                    mod.Size < 1048576 ? string.Format("{0:0} KB", Math.Ceiling(mod.Size / 1024.0)) : string.Format("{0:0.0} MB", mod.Size / 1048576.0),
                    RepoStatus(mod, local != null, recorded),
                }) { Tag = mod };
                repoList.Items.Add(item);
                if (mod.Name == selected) { item.Selected = true; }
            }
            UpdateInstallButton();
        }

        void UpdateInstallButton()
        {
            install.Enabled = !busy && repoList.SelectedItems.Count > 0;
            if (repoList.SelectedItems.Count == 0) { return; }
            string status = repoList.SelectedItems[0].SubItems[3].Text;
            install.Text = status == "Not installed" ? "Install" : status == "Up to date" ? "Reinstall" : "Update";
        }

        void Fill(int selected)
        {
            filling = true;
            list.Items.Clear();
            foreach (ModInfo mod in mods) { list.Items.Add(mod.Line, mod.Enabled || mod.AlwaysOn); }
            filling = false;
            if (mods.Count > 0) { list.SelectedIndex = Math.Max(0, Math.Min(selected, mods.Count - 1)); }
            ShowWarnings();
        }

        void ListItemCheck(object sender, ItemCheckEventArgs e)
        {
            if (filling) { return; }
            ModInfo mod = mods[e.Index];
            if (mod.AlwaysOn)
            {
                e.NewValue = CheckState.Checked;
                return;
            }
            mod.Enabled = e.NewValue == CheckState.Checked;
            ShowWarnings();
        }

        void MoveSelected(int by)
        {
            int from = list.SelectedIndex, to = from + by;
            if (from < 0 || to < 0 || to >= mods.Count) { return; }
            ModInfo mod = mods[from];
            mods.RemoveAt(from);
            mods.Insert(to, mod);
            Fill(to);
        }

        void ShowDetails()
        {
            if (list.SelectedIndex < 0) { return; }
            ModInfo mod = mods[list.SelectedIndex];
            var lines = new List<string> { mod.Line };
            if (mod.Author != "") { lines.Add("By " + mod.Author); }
            lines.Add("");
            if (mod.Description != "") { lines.Add(mod.Description); lines.Add(""); }
            if (mod.Keys.Count > 0) { lines.Add("Keys: " + string.Join(", ", mod.Keys)); }
            if (mod.Requires.Count > 0) { lines.Add("Needs: " + string.Join(", ", mod.Requires)); }
            if (mod.AlwaysOn) { lines.Add("Other mods rely on this one, so it stays on."); }
            if (mod.Preset) { lines.Add("Preset: comes with the mod loader."); }
            lines.Add("Folder: " + mod.Dir);
            details.Text = string.Join(Environment.NewLine, lines);
        }

        void ShowWarnings()
        {
            var problems = new List<Problem>();
            Registry.Resolve(mods, problems);
            warnings.Text = problems.Count == 0
                ? "No problems. Mods load from the top of the list down."
                : string.Join(Environment.NewLine, problems.Select(p => p.Text));
        }
    }
}
