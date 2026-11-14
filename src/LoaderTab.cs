// The Mod Manager's Mod Loader tab: which game, whether the loader is in it, and the buttons that install, update,
// repair and remove it. It replaces the old patch window. Work on the game's own SinSpire.exe (which is this program
// when the Mod Manager was opened from the game) is handed to a copy in the temp folder; see App.HandOver.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace SinSpireModLoader
{
    partial class ManagerForm
    {
        readonly ComboBox gameBox = new ComboBox { Dock = DockStyle.Fill };
        readonly Button browseGame = new Button { Text = "Browse...", AutoSize = true };
        readonly Label loaderState = new Label { AutoSize = true, Dock = DockStyle.Fill, Padding = new Padding(0, 6, 0, 6) };
        readonly TextBox loaderLog = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical };
        readonly Button installLoader = new Button { Text = "Install Mod Loader", AutoSize = true };
        readonly Button updateLoader = new Button { Text = "Update", AutoSize = true };
        readonly Button repairLoader = new Button { Text = "Repair", AutoSize = true };
        readonly Button removeLoader = new Button { Text = "Remove Mod Loader", AutoSize = true };
        readonly Button checkLoader = new Button { Text = "Check for Updates", AutoSize = true };
        readonly CheckBox startMenu = new CheckBox { Text = "Add " + App.Name + " to the Start menu", AutoSize = true, Checked = true };
        PatchRelease loaderRelease;
        string loaderCheck = "Not checked for updates yet.";
        bool loaderBusy, switching;
        string bundledUe4ss;

        bool LoaderInstalled
        {
            get { return game != null && game.LooksLikeTheGame && Patch.IsLauncher(game.Exe) && File.Exists(game.OriginalExe); }
        }

        // The Mod Manager opened from the game is the game's SinSpire.exe itself.
        bool InGameFolder
        {
            get { return game != null && string.Equals(App.Self, game.Exe, StringComparison.OrdinalIgnoreCase); }
        }

        Control BuildLoaderPage()
        {
            browseGame.Click += (s, e) => BrowseForGame();
            gameBox.SelectionChangeCommitted += (s, e) => SwitchGame(gameBox.SelectedItem as string);
            installLoader.Click += (s, e) => RunLoader("install");
            repairLoader.Click += (s, e) => RunLoader("repair");
            removeLoader.Click += (s, e) => RunLoader("remove");
            updateLoader.Click += (s, e) => UpdateLoader();
            checkLoader.Click += async (s, e) => await CheckLoaderRelease();
            gameBox.DropDownStyle = standalone ? ComboBoxStyle.DropDown : ComboBoxStyle.DropDownList;
            gameBox.Enabled = browseGame.Enabled = standalone;
            if (game != null) { gameBox.Items.Add(game.Root); gameBox.SelectedIndex = 0; }

            tips.SetToolTip(gameBox, "The Sin Spire folder this works on, the one with SinSpire.exe in it.");
            tips.SetToolTip(browseGame, "Choose the game's folder yourself. In Steam: right-click Sin Spire > Manage > Browse local files.");
            tips.SetToolTip(installLoader, "Install the mod loader and UE4SS in this game, and the preset mods from the mod list. Your saves are not touched.");
            tips.SetToolTip(updateLoader, "Download the new version of the " + App.Name + ", update the mod loader in the game, and open this window again. Your mods, their settings and your saves stay as they are.");
            tips.SetToolTip(repairLoader, "Install the mod loader again over itself, for example after a Steam update or file check turned it off. Your mods stay as they are.");
            tips.SetToolTip(removeLoader, "Put the game's own exe back and stop loading mods. Your Mods folder is kept, and a UE4SS the loader replaced comes back.");
            tips.SetToolTip(checkLoader, "Ask GitHub now whether a new version is out.");
            tips.SetToolTip(startMenu, "Adds a Start menu entry that opens this Mod Manager, so you don't need this download again.");

            var folderRow = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, ColumnCount = 3 };
            folderRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            folderRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            folderRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            folderRow.Controls.Add(new Label { Text = "Sin Spire folder", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 0);
            folderRow.Controls.Add(gameBox, 1, 0);
            folderRow.Controls.Add(browseGame, 2, 0);
            var buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true };
            buttons.Controls.AddRange(new Control[] { installLoader, updateLoader, repairLoader, removeLoader, checkLoader });

            var page = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 5, Padding = new Padding(8) };
            page.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            page.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            page.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            page.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            page.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            page.Controls.Add(folderRow, 0, 0);
            page.Controls.Add(loaderState, 0, 1);
            page.Controls.Add(buttons, 0, 2);
            page.Controls.Add(startMenu, 0, 3);
            page.Controls.Add(loaderLog, 0, 4);
            return page;
        }

        // When the window opens: the other Sin Spire folders the quick search finds (the app), then a check for updates.
        async void LoaderShown()
        {
            if (standalone)
            {
                try
                {
                    List<FoundGame> found = await Task.Run(() => GameSearch.Quick());
                    foreach (FoundGame other in found.Where(f => !gameBox.Items.Cast<string>().Contains(f.Folder, StringComparer.OrdinalIgnoreCase)))
                    {
                        gameBox.Items.Add(other.Folder);
                    }
                }
                catch (Exception) { }
            }
            if (game != null && LoaderInstalled) { loaderRelease = Updater.Pending(game); }
            ShowLoader();
            await CheckLoaderRelease();
        }

        async Task CheckLoaderRelease()
        {
            checkLoader.Enabled = false;
            GameFolder checking = game;
            bool installed = LoaderInstalled;
            try
            {
                // Remembered in the game only when the loader is there, so a folder it isn't in stays as it was.
                loaderRelease = await Task.Run(() => installed ? Updater.CheckNow(checking) : Updater.Latest());
                loaderCheck = loaderRelease == null ? "No release found on GitHub." : null;
            }
            catch (Exception error)
            {
                loaderCheck = "Couldn't check for updates: " + error.Message;
            }
            checkLoader.Enabled = !loaderBusy;
            ShowLoader();
        }

        void ShowLoader()
        {
            var lines = new List<string>();
            bool installed = LoaderInstalled, running = false, newer = false;
            if (game == null)
            {
                lines.Add("Sin Spire wasn't found. Click Browse... and choose its folder (in Steam: right-click Sin Spire > Manage > Browse local files).");
            }
            else if (!game.LooksLikeTheGame)
            {
                lines.Add("That folder isn't Sin Spire. Choose the folder with SinSpire.exe in it.");
            }
            else
            {
                running = game.GameIsRunning();
                if (installed)
                {
                    lines.Add("Mod loader: installed, " + (Updater.InstalledTag(game) ?? "a version from before 2026-11-14") + ".");
                    string ue4ss = Path.Combine(game.Ue4ss, "UE4SS.dll");
                    if (bundledUe4ss == null) { try { bundledUe4ss = Patch.BundledUe4ssSha256(); } catch (Exception) { bundledUe4ss = ""; } }
                    bool rightUe4ss = File.Exists(ue4ss) && Sha256(ue4ss) == bundledUe4ss;
                    lines.Add(rightUe4ss ? "UE4SS: the build the mods are made for." : "UE4SS: missing or a different build. Repair puts the right one in.");
                }
                else
                {
                    lines.Add("Mod loader: not installed in this game yet. Install Mod Loader puts it in, with UE4SS and the preset mods.");
                }
                if (running) { lines.Add("Sin Spire is running: close it to install, update, repair or remove the loader."); }
            }
            lines.Add("This " + App.Name + ": " + (Patch.Tag ?? "a test build") + ".");
            if (loaderCheck != null) { lines.Add(loaderCheck); }
            else
            {
                // Newer than this program, or than the loader in the game.
                newer = Updater.IsNewer(loaderRelease.Tag, Patch.Tag) || (installed && Updater.IsNewer(loaderRelease.Tag, Updater.InstalledTag(game)));
                lines.Add(newer ? "A new version is out: " + loaderRelease.Tag + (loaderRelease.Name != "" ? " (" + loaderRelease.Name + ")" : "") + ". Click Update."
                                : "You have the latest version.");
            }
            loaderState.Text = string.Join(Environment.NewLine, lines);

            bool ready = game != null && game.LooksLikeTheGame && !running && !loaderBusy;
            installLoader.Visible = !installed;
            installLoader.Enabled = ready;
            repairLoader.Visible = removeLoader.Visible = installed;
            repairLoader.Enabled = removeLoader.Enabled = ready;
            updateLoader.Visible = newer;
            updateLoader.Enabled = newer && !running && !loaderBusy;
            startMenu.Visible = !removeLoader.Visible || !Shortcut.Exists;
            play.Enabled = installed && !busy && !loaderBusy;
        }

        static string Sha256(string file)
        {
            using (Stream stream = File.OpenRead(file))
            using (var sha = System.Security.Cryptography.SHA256.Create())
            {
                return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "");
            }
        }

        void SetLoaderBusy(bool value)
        {
            loaderBusy = value;
            browseGame.Enabled = gameBox.Enabled = standalone && !value;
            ShowLoader();
        }

        void BrowseForGame()
        {
            using (var dialog = new FolderBrowserDialog { Description = "Choose the Sin Spire folder, the one with SinSpire.exe in it." })
            {
                while (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    string chosen = GameSearch.ResolveChoice(dialog.SelectedPath);
                    if (chosen != null)
                    {
                        if (!gameBox.Items.Cast<string>().Contains(chosen, StringComparer.OrdinalIgnoreCase)) { gameBox.Items.Add(chosen); }
                        gameBox.SelectedItem = gameBox.Items.Cast<string>().First(i => string.Equals(i, chosen, StringComparison.OrdinalIgnoreCase));
                        SwitchGame(chosen);
                        return;
                    }
                    MessageBox.Show(this, "Sin Spire was not found in that folder. Choose the folder with SinSpire.exe in it.", Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
            }
        }

        // Works on another game folder: the list of mods, Get Mods and this tab follow it, and the app remembers it.
        void SwitchGame(string folder)
        {
            if (string.IsNullOrEmpty(folder) || switching) { return; }
            switching = true;
            try
            {
                if (game != null && string.Equals(game.Root, Path.GetFullPath(folder).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) { return; }
                SaveList();
                game = new GameFolder(folder);
                if (standalone && game.LooksLikeTheGame) { Settings.Set("game", game.Root); }
                ReloadGame();
            }
            finally { switching = false; }
        }

        void ReloadGame()
        {
            mods.Clear();
            if (game != null && Directory.Exists(game.Mods)) { mods.AddRange(Registry.Load(game)); }
            Fill(0);
            FillRepo();
            ShowLoader();
        }

        void Say(string line)
        {
            if (InvokeRequired) { BeginInvoke(new Action<string>(Say), line); return; }
            loaderLog.AppendText(line + Environment.NewLine);
        }

        async void RunLoader(string job)
        {
            if (game == null || !game.LooksLikeTheGame) { return; }
            if (game.GameIsRunning()) { MessageBox.Show(this, "Close Sin Spire first.", Text, MessageBoxButtons.OK, MessageBoxIcon.Warning); return; }
            bool remove = job == "remove";
            if (remove && MessageBox.Show(this, "Remove the mod loader from this game? Your Mods folder is kept, so installing it again brings your mods back.",
                Text, MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) { return; }
            SaveList();
            if (InGameFolder)
            {
                // This program is the game's SinSpire.exe, which the work replaces or deletes: a copy does it instead.
                App.HandOver(remove ? "remove" : "install", game, startMenu.Visible && startMenu.Checked);
                Close();
                return;
            }
            GameFolder target = game;
            bool shortcut = startMenu.Visible && startMenu.Checked;
            loaderLog.Clear();
            SetBusy(true, repoStatus.Text); // also keeps the window open until it's done
            try
            {
                await Task.Run(() =>
                {
                    var report = new List<string>();
                    Action<string> say = line => { report.Add(line); Say(line); };
                    try
                    {
                        if (remove) { Patch.Remove(target, say); Shortcut.Remove(target, say); }
                        else { Patch.Apply(target, say); if (shortcut) { Shortcut.Create(target, say); } }
                    }
                    finally { foreach (string line in report) { target.Log(line); } }
                });
            }
            catch (Exception error)
            {
                Say("Failed: " + error.Message);
                target.Log("Failed: " + error);
            }
            SetBusy(false, repoStatus.Text);
            ReloadGame();
        }

        // The new version is downloaded and checked, then started to replace this one: it updates the game's loader, puts
        // itself in place of this app when this is the downloaded app, and opens the Mod Manager again.
        void UpdateLoader()
        {
            if (loaderRelease == null) { return; }
            SaveList();
            string appPath = standalone && !InGameFolder ? App.Self : null;
            string then = InGameFolder ? "-modmanager" : "";
            if (Updater.DownloadAndStart(LoaderInstalled ? game : null, loaderRelease, then, this, appPath)) { Close(); }
        }
    }
}
