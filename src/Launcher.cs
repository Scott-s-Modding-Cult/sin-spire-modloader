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
        }
    }

    class ManagerForm : Form
    {
        readonly GameFolder game;
        readonly List<ModInfo> mods;
        readonly CheckedListBox list = new CheckedListBox { Dock = DockStyle.Fill, CheckOnClick = true, IntegralHeight = false };
        readonly TextBox details = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical };
        readonly TextBox warnings = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical };
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
            var play = new Button { Text = "Save and Play", AutoSize = true };
            var close = new Button { Text = "Save and Close", AutoSize = true };
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
            layout.Controls.Add(right, 1, 2);
            Controls.Add(layout);

            Fill(0);
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
