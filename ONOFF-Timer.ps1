param([switch]$Minimized, [int]$AutoAction = -1, [int]$AutoDelay = 60, [int]$Alarm = -1, [string]$AlarmFile = '', [string]$AlarmAt = '')
# ON/OFF Timer - таймер сна, расписание и будильник для Windows 10/11 (PowerShell + WinForms).
# Лицензия MIT. Установка не нужна: запускайте через "ON-OFF Timer.vbs" (без окна терминала) или "ON-OFF Timer.cmd".
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
if (-not ('Pwr' -as [type])) { Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class Pwr {
 [DllImport("PowrProf.dll")] public static extern bool SetSuspendState(bool hibernate, bool force, bool wakeDisable);
 [DllImport("user32.dll")] public static extern bool LockWorkStation();
 [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);
 [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
 [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
}
public class Snd {
 public static byte[] Tone(double[] f, double[] st, double[] amp, double dur, double decay) {
  int sr = 22050, n = (int)(sr * dur);
  var ms = new System.IO.MemoryStream(); var w = new System.IO.BinaryWriter(ms);
  w.Write(new byte[]{82,73,70,70}); w.Write(36 + n*2); w.Write(new byte[]{87,65,86,69,102,109,116,32});
  w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(sr); w.Write(sr*2); w.Write((short)2); w.Write((short)16);
  w.Write(new byte[]{100,97,116,97}); w.Write(n*2);
  for (int i = 0; i < n; i++) {
   double t = (double)i / sr, v = 0;
   for (int k = 0; k < f.Length; k++) { double tt = t - st[k]; if (tt >= 0) v += amp[k] * Math.Sin(2*Math.PI*f[k]*tt) * Math.Exp(-decay*tt) * Math.Min(1.0, tt*60); }
   if (v > 1) v = 1; if (v < -1) v = -1; w.Write((short)(v * 9000));
  }
  w.Flush(); return ms.ToArray();
 }
}
"@ }
[void][Pwr]::SetProcessDPIAware()
$hc = [Pwr]::GetConsoleWindow(); if ($hc -ne [IntPtr]::Zero -and -not $HostExe) { [void][Pwr]::ShowWindow($hc, 0) }   # прячем окно консоли
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:auto = ($AutoAction -ge 0); $script:alarmMode = ($Alarm -ge 0); if ($HostExe) { $script:exeMode = $true; $script:selfPath = $HostExe } else { $script:exeMode = $false; $script:selfPath = $PSCommandPath }
$mutex = New-Object System.Threading.Mutex($false, $(if ($script:auto) { 'Local\SleepTimerPS1Auto' } elseif ($script:alarmMode) { 'Local\SleepTimerPS1Alarm' } else { 'Local\SleepTimerPS1' }))
if (-not $mutex.WaitOne(0)) { [void][System.Windows.Forms.MessageBox]::Show('Таймер уже запущен (значок в трее).','ON/OFF Timer'); return }

# ---------- Настройки ----------
$dir = Join-Path $env:APPDATA 'ONOFF-Timer'
$d2 = $(if ($script:exeMode) { Split-Path $script:selfPath } else { $PSScriptRoot })
if ($d2) { try { $w = Join-Path $d2 '.write-test'; Set-Content $w 1 -ErrorAction Stop; Remove-Item $w; $dir = $d2 } catch {} }
$cfgFile = Join-Path $dir 'ONOFF-Timer.settings.json'
$cfg = [ordered]@{ Action=0; H=0; M=30; Mode=0; At='23:00'; Warn=$true; WarnSec=60; Force=$false; Fade=$false; Top=$false; Tray=$true; Snd=1; SoundFile=''; LnkAsked=$false }
if (Test-Path $cfgFile) { try { $j = Get-Content $cfgFile -Raw | ConvertFrom-Json; foreach ($k in @($cfg.Keys)) { if ($null -ne $j.$k) { $cfg[$k] = $j.$k } } } catch {} }

$actions = @('Сон','Гибернация','Выключение','Перезагрузка','Выход из системы','Блокировка экрана','Выключить монитор')
$script:running = $false; $script:warned = $false; $script:exiting = $false
$script:warnForm = $null; $script:lastFade = Get-Date; $script:lastBeep = -1; $script:target = Get-Date; $script:total = 1

function New-Ctl($type, $x, $y, $w, $h, $text) {
    $c = New-Object $type; $c.Location = New-Object System.Drawing.Point($x, $y); $c.Size = New-Object System.Drawing.Size($w, $h)
    if ($text) { $c.Text = $text }; $c
}
function Format-Span($s) { $s = [math]::Max(0, [int][math]::Ceiling($s)); '{0:00}:{1:00}:{2:00}' -f [math]::Floor($s/3600), [math]::Floor(($s%3600)/60), ($s%60) }

function New-AppIcon {
    $bmp = New-Object System.Drawing.Bitmap 32,32; $g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'
    $blue = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(40,70,160))
    $g.FillRectangle($blue,0,0,32,32); $g.FillEllipse([System.Drawing.Brushes]::White,6,6,20,20); $g.FillEllipse($blue,12,2,20,20); $g.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$appDir = $(if ($script:exeMode) { Split-Path $script:selfPath } else { $PSScriptRoot })
$icoPath = Join-Path $appDir 'ON-OFF Timer.ico'
$icon = $null; $trayIcon = $null
if (Test-Path $icoPath) { try { $icon = New-Object System.Drawing.Icon($icoPath, 32, 32); $trayIcon = New-Object System.Drawing.Icon($icoPath, 16, 16) } catch {} }
if (-not $icon) { $icon = New-AppIcon }
if (-not $trayIcon) { $trayIcon = $icon }

# ---------- Действия ----------
function Invoke-Act($i) {
    switch ($i) {
        0 { [void][Pwr]::SetSuspendState($false, $false, $false) }
        1 { [void][Pwr]::SetSuspendState($true, $false, $false) }
        2 { $a = '/s /t 0'; if ($cfg.Force) { $a += ' /f' }; Start-Process shutdown.exe $a -WindowStyle Hidden }
        3 { $a = '/r /t 0'; if ($cfg.Force) { $a += ' /f' }; Start-Process shutdown.exe $a -WindowStyle Hidden }
        4 { $a = '/l'; if ($cfg.Force) { $a += ' /f' }; Start-Process shutdown.exe $a -WindowStyle Hidden }
        5 { [void][Pwr]::LockWorkStation() }
        6 { [void][Pwr]::SendMessage([IntPtr]0xFFFF, 0x0112, [IntPtr]0xF170, [IntPtr]2) }
    }
}

function Play-Wav($bytes) {
    if ($script:player) { $script:player.Stop(); $script:player.Dispose() }
    $script:player = New-Object System.Media.SoundPlayer (New-Object System.IO.MemoryStream -ArgumentList (,$bytes)); $script:player.Play()
}
function Play-Alert($idx = -1) {
    if ($idx -lt 0) { $idx = $cbSound.SelectedIndex }
    try {
        switch ($idx) {
            1 { if (-not $script:wBell) { $script:wBell = [Snd]::Tone([double[]](1046.5,1318.5,1568), [double[]](0,0.18,0.36), [double[]](0.6,0.5,0.4), 1.8, 3.0) }; Play-Wav $script:wBell }
            2 { if (-not $script:wGong) { $script:wGong = [Snd]::Tone([double[]](261.6,523.2,785), [double[]](0,0,0), [double[]](0.55,0.25,0.12), 2.5, 1.8) }; Play-Wav $script:wGong }
            3 { [Console]::Beep(880, 150); [Console]::Beep(1175, 150) }
            4 { [System.Media.SystemSounds]::Exclamation.Play() }
            5 { [System.Media.SystemSounds]::Beep.Play() }
            6 { if ($cfg.SoundFile -and (Test-Path $cfg.SoundFile)) { (New-Object System.Media.SoundPlayer $cfg.SoundFile).Play() } else { [System.Media.SystemSounds]::Exclamation.Play() } }
        }
    } catch {}
}

# ---------- Главное окно ----------
$form = New-Ctl System.Windows.Forms.Form 0 0 410 585 'ON/OFF Timer'
$form.ClientSize = New-Object System.Drawing.Size(410, 585)
$form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9); $form.Icon = $icon; $form.TopMost = [bool]$cfg.Top

$lblAct = New-Ctl System.Windows.Forms.Label 15 12 200 20 'Что сделать:'
$cbAct = New-Ctl System.Windows.Forms.ComboBox 15 34 380 25; $cbAct.DropDownStyle = 'DropDownList'
$cbAct.Items.AddRange($actions); $cbAct.SelectedIndex = [int]$cfg.Action

$gb = New-Ctl System.Windows.Forms.GroupBox 15 68 380 94 'Когда'
$rbIn = New-Ctl System.Windows.Forms.RadioButton 15 26 70 22 'Через'
$nH = New-Ctl System.Windows.Forms.NumericUpDown 90 24 55 24; $nH.Maximum = 99; $nH.Value = [decimal]$cfg.H
$l1 = New-Ctl System.Windows.Forms.Label 148 28 18 20 'ч'
$nM = New-Ctl System.Windows.Forms.NumericUpDown 170 24 55 24; $nM.Maximum = 59; $nM.Value = [decimal]$cfg.M
$l2 = New-Ctl System.Windows.Forms.Label 228 28 40 20 'мин'
$rbAt = New-Ctl System.Windows.Forms.RadioButton 15 60 70 22 'В'
$dtp = New-Ctl System.Windows.Forms.DateTimePicker 90 58 90 24; $dtp.Format = 'Time'; $dtp.ShowUpDown = $true
try { $dtp.Value = [datetime]::Today.Add([timespan]::Parse([string]$cfg.At)) } catch {}
$rbIn.Checked = ($cfg.Mode -eq 0); $rbAt.Checked = -not $rbIn.Checked
$gb.Controls.AddRange(@($rbIn,$nH,$l1,$nM,$l2,$rbAt,$dtp))

$presets = 15,30,45,60,90,120
for ($i = 0; $i -lt 6; $i++) {
    $b = New-Ctl System.Windows.Forms.Button (15 + $i*64) 172 60 28 ("{0}м" -f $presets[$i]); $b.Tag = $presets[$i]
    $b.Add_Click({ $m = [int]$this.Tag; $nH.Value = [math]::Floor($m/60); $nM.Value = $m % 60; $rbIn.Checked = $true })
    $form.Controls.Add($b)
}

$chkWarn = New-Ctl System.Windows.Forms.CheckBox 15 210 170 22 'Предупредить за'; $chkWarn.Checked = [bool]$cfg.Warn
$nW = New-Ctl System.Windows.Forms.NumericUpDown 190 208 65 24; $nW.Minimum = 5; $nW.Maximum = 900; $nW.Value = [decimal]$cfg.WarnSec
$l3 = New-Ctl System.Windows.Forms.Label 260 212 40 20 'сек'
$chkSound = New-Ctl System.Windows.Forms.Label 15 243 90 22 'Звук:'
$cbSound = New-Ctl System.Windows.Forms.ComboBox 105 238 190 25; $cbSound.DropDownStyle = 'DropDownList'
$cbSound.Items.AddRange(@('Без звука','Мягкий колокольчик','Тихий гонг','Двойной сигнал (громкий)','Звук Windows: восклицание','Звук Windows: сигнал','Свой файл (.wav)...'))
$si = [int]$cfg.Snd; if ($si -lt 0 -or $si -gt 6) { $si = 1 }; $cbSound.SelectedIndex = $si
$btnTest = New-Ctl System.Windows.Forms.Button 301 237 94 27 'Проверить'
$chkForce = New-Ctl System.Windows.Forms.CheckBox 15 272 380 22 'Принудительно закрывать программы'; $chkForce.Checked = [bool]$cfg.Force
$chkFade = New-Ctl System.Windows.Forms.CheckBox 15 296 380 22 'Убавлять громкость в последнюю минуту'; $chkFade.Checked = [bool]$cfg.Fade
$chkTop = New-Ctl System.Windows.Forms.CheckBox 15 320 380 22 'Окно поверх остальных'; $chkTop.Checked = [bool]$cfg.Top
$chkTray = New-Ctl System.Windows.Forms.CheckBox 15 344 380 22 'Сворачивать в трей'; $chkTray.Checked = [bool]$cfg.Tray
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$chkAuto = New-Ctl System.Windows.Forms.CheckBox 15 368 380 22 'Запускать вместе с Windows'
$chkAuto.Checked = [bool](Get-ItemProperty $runKey -Name ONOFFTimer -ErrorAction SilentlyContinue)

$lbl = New-Ctl System.Windows.Forms.Label 15 398 380 52 '00:00:00'
$lbl.Font = New-Object System.Drawing.Font('Segoe UI', 30, [System.Drawing.FontStyle]::Bold); $lbl.TextAlign = 'MiddleCenter'
$lblInfo = New-Ctl System.Windows.Forms.Label 15 452 380 20 'Таймер не запущен'; $lblInfo.TextAlign = 'MiddleCenter'
$pb = New-Ctl System.Windows.Forms.ProgressBar 15 478 380 12
$btnGo = New-Ctl System.Windows.Forms.Button 15 498 200 34 'Запустить'
$btn5 = New-Ctl System.Windows.Forms.Button 222 498 84 34 '+5 мин'; $btn5.Enabled = $false
$btn15 = New-Ctl System.Windows.Forms.Button 312 498 83 34 '+15 мин'; $btn15.Enabled = $false
$btnSched = New-Ctl System.Windows.Forms.Button 15 542 380 32 'Расписание и будильник...'
$form.Controls.AddRange(@($lblAct,$cbAct,$gb,$chkWarn,$nW,$l3,$chkSound,$cbSound,$btnTest,$chkForce,$chkFade,$chkTop,$chkTray,$chkAuto,$lbl,$lblInfo,$pb,$btnGo,$btn5,$btn15,$btnSched))

$tip = New-Object System.Windows.Forms.ToolTip
$tip.SetToolTip($chkForce, 'Программы закроются БЕЗ сохранения данных')
$tip.SetToolTip($chkTray, 'Закрытие и сворачивание окна уберёт его в трей')
$tip.SetToolTip($chkAuto, 'Запуск при входе в Windows, окно скрыто в трее')

# ---------- Трей ----------
$tray = New-Object System.Windows.Forms.NotifyIcon; $tray.Icon = $trayIcon; $tray.Text = 'ON/OFF Timer'; $tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$mOpen = $menu.Items.Add('Открыть'); $m15 = $menu.Items.Add('+15 минут'); $mStop = $menu.Items.Add('Отменить таймер'); $mLnk = $menu.Items.Add('Создать ярлык на рабочем столе'); $mExit = $menu.Items.Add('Выход')
$tray.ContextMenuStrip = $menu

function Get-Launch($extra) {
    if ($script:exeMode) { @($script:selfPath, ('-Minimized ' + $extra)) }
    else { @('powershell.exe', ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Minimized {1}' -f $script:selfPath, $extra)) }
}
function New-DesktopShortcut($manual) {
    try {
        $target = Join-Path $appDir 'ON-OFF Timer.vbs'
        if (-not (Test-Path $target)) { $target = Join-Path $appDir 'ON-OFF Timer.cmd' }
        if (-not (Test-Path $target)) { if ($manual) { [void][System.Windows.Forms.MessageBox]::Show('Файл запуска не найден рядом со скриптом.', 'ON/OFF Timer') }; return }
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'ON-OFF Timer.lnk'))
        $lnk.TargetPath = $target; $lnk.WorkingDirectory = $appDir; $lnk.Description = 'ON/OFF Timer'
        if (Test-Path $icoPath) { $lnk.IconLocation = $icoPath }
        $lnk.Save()
        [void][System.Windows.Forms.MessageBox]::Show('Ярлык ON-OFF Timer создан на рабочем столе.', 'ON/OFF Timer')
    } catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'ON/OFF Timer') }
}
function Show-Main { $form.Show(); $form.WindowState = 'Normal'; $form.Activate() }

function Save-Cfg {
    if ($script:auto -or $script:alarmMode) { return }
    try {
        $cfg.Action = $cbAct.SelectedIndex; $cfg.H = [int]$nH.Value; $cfg.M = [int]$nM.Value; $cfg.Mode = $(if ($rbIn.Checked) { 0 } else { 1 })
        $cfg.At = $dtp.Value.ToString('HH:mm'); $cfg.Warn = $chkWarn.Checked; $cfg.WarnSec = [int]$nW.Value; $cfg.Force = $chkForce.Checked
        $cfg.Fade = $chkFade.Checked; $cfg.Top = $chkTop.Checked; $cfg.Tray = $chkTray.Checked; $cfg.Snd = $cbSound.SelectedIndex
        New-Item -ItemType Directory -Force $dir | Out-Null
        $cfg | ConvertTo-Json | Set-Content $cfgFile -Encoding UTF8
    } catch {}
}

# ---------- Окно предупреждения ----------
function Close-Warn { if ($script:warnForm) { $script:warnForm.Close(); $script:warnForm.Dispose(); $script:warnForm = $null } }

function Show-Warn {
    $f = New-Ctl System.Windows.Forms.Form 0 0 420 200 'Скоро отключение'
    $f.ClientSize = New-Object System.Drawing.Size(420, 190); $f.StartPosition = 'CenterScreen'; $f.FormBorderStyle = 'FixedDialog'
    $f.ControlBox = $false; $f.TopMost = $true; $f.ShowInTaskbar = $false; $f.Icon = $icon; $f.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $t = New-Ctl System.Windows.Forms.Label 15 15 390 26 ("Скоро: " + $actions[$cbAct.SelectedIndex]); $t.TextAlign = 'MiddleCenter'
    $big = New-Ctl System.Windows.Forms.Label 15 45 390 64 '00'; $big.Name = 'big'; $big.TextAlign = 'MiddleCenter'
    $big.Font = New-Object System.Drawing.Font('Segoe UI', 36, [System.Drawing.FontStyle]::Bold)
    $b1 = New-Ctl System.Windows.Forms.Button 15 130 125 40 'Отложить на 10 мин'
    $b2 = New-Ctl System.Windows.Forms.Button 148 130 125 40 'Отменить таймер'
    $b3 = New-Ctl System.Windows.Forms.Button 281 130 125 40 'Выполнить сейчас'
    $b1.Add_Click({ Add-Minutes 10 }); $b2.Add_Click({ Stop-Timer }); $b3.Add_Click({ Invoke-Now })
    $f.Controls.AddRange(@($t,$big,$b1,$b2,$b3)); $script:warnForm = $f
    $f.Show(); $f.Activate()
}

# ---------- Логика таймера ----------
function Set-UI($on) {
    $cbAct.Enabled = -not $on; $gb.Enabled = -not $on; $btn5.Enabled = $on; $btn15.Enabled = $on
    $btnGo.Text = $(if ($on) { 'Отменить' } else { 'Запустить' })
}

function Start-Timer($fs = 0) {
    if ($fs -gt 0) { $sec = [double]$fs }
    elseif ($rbIn.Checked) { $sec = [double]($nH.Value * 3600 + $nM.Value * 60) }
    else { $now = Get-Date; $tg = Get-Date -Hour $dtp.Value.Hour -Minute $dtp.Value.Minute -Second 0; if ($tg -le $now) { $tg = $tg.AddDays(1) }; $sec = ($tg - $now).TotalSeconds }
    if ($sec -lt 1) { [void][System.Windows.Forms.MessageBox]::Show('Укажите время больше нуля.','ON/OFF Timer'); return }
    Save-Cfg
    $script:total = $sec; $script:target = (Get-Date).AddSeconds($sec); $script:warned = $false; $script:running = $true; $script:lastBeep = -1
    Set-UI $true; $timer.Start()
    $lblInfo.Text = "{0} в {1:HH:mm:ss}" -f $actions[$cbAct.SelectedIndex], $script:target
}

function Stop-Timer($keep = $false) {
    $script:running = $false; $timer.Stop(); Close-Warn; Set-UI $false
    $lbl.Text = '00:00:00'; $lblInfo.Text = 'Таймер не запущен'; $pb.Value = 0; $tray.Text = 'ON/OFF Timer'
    if ($script:auto -and -not $keep -and -not $script:exiting) { Exit-App }
}

function Add-Minutes($m) {
    if (-not $script:running) { return }
    $script:target = $script:target.AddMinutes($m); $script:total += $m * 60; $script:warned = $false; $script:lastBeep = -1; Close-Warn
    $lblInfo.Text = "{0} в {1:HH:mm:ss}" -f $actions[$cbAct.SelectedIndex], $script:target
}

function Invoke-Now { $i = $cbAct.SelectedIndex; Stop-Timer $true; Invoke-Act $i; if ($script:auto) { Exit-App } }

$timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 500
$timer.Add_Tick({
    if (-not $script:running) { return }
    $rem = ($script:target - (Get-Date)).TotalSeconds
    if ($rem -le 0) { Invoke-Now; return }
    $lbl.Text = Format-Span $rem
    $pb.Value = [int][math]::Min(100, [math]::Max(0, 100 * (1 - $rem / $script:total)))
    $tray.Text = ("{0}: {1}" -f $actions[$cbAct.SelectedIndex], (Format-Span $rem))
    $lim = $(if ($script:auto) { [double]$script:AutoDelay } else { [double]$nW.Value })
    if (($chkWarn.Checked -or $script:auto) -and -not $script:warned -and $rem -le $lim) {
        $script:warned = $true; Show-Warn
        $tray.ShowBalloonTip(5000, 'ON/OFF Timer', ("Через {0} сек: {1}" -f [int]$rem, $actions[$cbAct.SelectedIndex]), 'Warning')
    }
    if ($script:warnForm) {
        $script:warnForm.Controls['big'].Text = [string][int][math]::Ceiling($rem)
        $sec = [int][math]::Ceiling($rem)
        if ($cbSound.SelectedIndex -ne 0 -and $sec -ne $script:lastBeep -and ($script:lastBeep -eq -1 -or $rem -le 10 -or $sec % 5 -eq 0)) { $script:lastBeep = $sec; Play-Alert }
    }
    if ($chkFade.Checked -and $rem -le 60 -and ((Get-Date) - $script:lastFade).TotalMilliseconds -ge 1200) {
        $script:lastFade = Get-Date; [Pwr]::keybd_event(0xAE, 0, 0, [UIntPtr]::Zero); [Pwr]::keybd_event(0xAE, 0, 2, [UIntPtr]::Zero)
    }
})

# ---------- Окно будильника (запускается заданием из планировщика) ----------
$script:alN = 0; $script:alSnooze = $null; $script:alForm = $null; $script:alWait = $false; $script:alProc = $null
$alTimer = New-Object System.Windows.Forms.Timer; $alTimer.Interval = 1000
function Wake-Display { try { [void][Pwr]::SendMessage([IntPtr]0xFFFF, 0x0112, [IntPtr]0xF170, [IntPtr](-1)) } catch {} }
function Start-AlarmPlay {
    Wake-Display
    $i = $script:alForm.Controls['info']
    if ($script:AlarmFile) {
        try { $script:alProc = Start-Process -FilePath $script:AlarmFile -PassThru } catch {}
        $n = $script:AlarmFile; if ($n.Length -gt 40) { $n = '...' + $n.Substring($n.Length - 40) }; $i.Text = 'Открыто: ' + $n
    } else { $i.Text = 'Играет: ' + $cbSound.Items[$script:Alarm] }
}
$alTimer.Add_Tick({
    $now = Get-Date
    if ($script:alSnooze) { if ($now -ge $script:alSnooze) { $script:alSnooze = $null; $script:alN = 0; $script:alForm.Show() }; return }
    $script:alForm.Controls['big'].Text = $now.ToString('HH:mm:ss')
    if ($script:alWait) {
        if ($now -lt $script:alTarget) { $script:alForm.Controls['info'].Text = 'До сигнала: ' + (Format-Span ($script:alTarget - $now).TotalSeconds); return }
        $script:alWait = $false; $script:alN = 0; Start-AlarmPlay
    }
    if ($script:Alarm -gt 0 -and $script:alN % 4 -eq 0) { Play-Alert $script:Alarm }
    $script:alN++
})
function Start-AlarmMode {
    [void][Pwr]::SetThreadExecutionState([Convert]::ToUInt32('80000003', 16)); Wake-Display
    $now = Get-Date; $tg = $now
    if ($script:AlarmAt) {
        try { $pt = [datetime]::ParseExact($script:AlarmAt, 'HH:mm', $null); $tg = Get-Date -Hour $pt.Hour -Minute $pt.Minute -Second 0; if (($tg - $now).TotalHours -lt -12) { $tg = $tg.AddDays(1) } } catch { $tg = $now }
    }
    $script:alTarget = $tg; $script:alWait = ($tg -gt $now)
    $f = New-Ctl System.Windows.Forms.Form 0 0 420 215 'Будильник'
    $f.ClientSize = New-Object System.Drawing.Size(420, 215); $f.StartPosition = 'CenterScreen'; $f.FormBorderStyle = 'FixedDialog'
    $f.ControlBox = $false; $f.TopMost = $true; $f.Icon = $icon; $f.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $title = $(if ($script:AlarmAt) { 'Будильник на ' + $script:AlarmAt } else { 'Будильник' })
    $t1 = New-Ctl System.Windows.Forms.Label 15 12 390 26 $title; $t1.TextAlign = 'MiddleCenter'
    $big = New-Ctl System.Windows.Forms.Label 15 42 390 64 $now.ToString('HH:mm:ss'); $big.Name = 'big'; $big.TextAlign = 'MiddleCenter'
    $big.Font = New-Object System.Drawing.Font('Segoe UI', 34, [System.Drawing.FontStyle]::Bold)
    $inf = New-Ctl System.Windows.Forms.Label 15 108 390 40 ''; $inf.Name = 'info'; $inf.TextAlign = 'MiddleCenter'
    $b1 = New-Ctl System.Windows.Forms.Button 15 160 190 40 'Выключить'
    $b2 = New-Ctl System.Windows.Forms.Button 215 160 190 40 'Ещё 5 минут'; $b2.Visible = (-not $script:AlarmFile)
    $b1.Add_Click({
        $alTimer.Stop(); if ($script:player) { $script:player.Stop() }
        try { if ($script:alProc -and -not $script:alProc.HasExited) { [void]$script:alProc.CloseMainWindow(); $script:alProc.Kill() } } catch {}
        Exit-App
    })
    $b2.Add_Click({ if ($script:player) { $script:player.Stop() }; $script:alSnooze = (Get-Date).AddMinutes(5); $script:alForm.Hide() })
    $f.Controls.AddRange(@($t1,$big,$inf,$b1,$b2)); $script:alForm = $f; $f.Show(); $f.Activate()
    if (-not $script:alWait) { Start-AlarmPlay }
    $alTimer.Start()
}

# ---------- Расписание и будильник (Планировщик заданий) ----------
$dow = 'Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'
$dshort = 'Пн','Вт','Ср','Чт','Пт','Сб','Вс'
$sd = New-Ctl System.Windows.Forms.Form 0 0 440 676 'Расписание и будильник'
$sd.ClientSize = New-Object System.Drawing.Size(440, 676); $sd.StartPosition = 'CenterScreen'; $sd.FormBorderStyle = 'FixedDialog'
$sd.MaximizeBox = $false; $sd.MinimizeBox = $false; $sd.Font = $form.Font; $sd.Icon = $icon
$sdL = New-Ctl System.Windows.Forms.Label 15 8 410 20 'Созданные задания (Планировщик заданий Windows):'
$sdList = New-Ctl System.Windows.Forms.ListBox 15 30 410 100
$sdDel = New-Ctl System.Windows.Forms.Button 15 134 410 28 'Удалить выбранное'
$sdG = New-Ctl System.Windows.Forms.GroupBox 15 172 410 450 'Новое задание'
$sdType = New-Ctl System.Windows.Forms.ComboBox 15 26 380 25; $sdType.DropDownStyle = 'DropDownList'
$sdType.Items.AddRange([object[]]($actions + 'Будильник (разбудить ПК)')); $sdType.SelectedIndex = 7
$sdT1 = New-Ctl System.Windows.Forms.Label 15 62 65 20 'Время:'
$sdTime = New-Ctl System.Windows.Forms.DateTimePicker 85 58 95 24; $sdTime.Format = 'Time'; $sdTime.ShowUpDown = $true
$sdTime.Value = [datetime]::Today.AddHours(23).AddMinutes(30)
$sdOnce = New-Ctl System.Windows.Forms.CheckBox 195 58 200 24 'Только один раз'; $sdOnce.Checked = $true
$sdDays = @(); for ($i = 0; $i -lt 7; $i++) { $c = New-Ctl System.Windows.Forms.CheckBox (15 + $i*56) 94 56 22 $dshort[$i]; $c.Checked = ($i -lt 5); $sdDays += $c; $sdG.Controls.Add($c) }
$sdT2 = New-Ctl System.Windows.Forms.Label 15 130 290 20 'Отсчёт перед действием (сек):'
$sdDelay = New-Ctl System.Windows.Forms.NumericUpDown 305 126 70 24; $sdDelay.Minimum = 5; $sdDelay.Maximum = 600; $sdDelay.Value = 60
$sdT2b = New-Ctl System.Windows.Forms.Label 15 130 290 20 'Проснуться заранее (мин):'
$sdLead = New-Ctl System.Windows.Forms.NumericUpDown 305 126 70 24; $sdLead.Minimum = 0; $sdLead.Maximum = 10; $sdLead.Value = 2
$sdT3 = New-Ctl System.Windows.Forms.Label 15 166 380 20 'Мелодия будильника:'
$sdMel = New-Ctl System.Windows.Forms.ComboBox 15 188 290 25; $sdMel.DropDownStyle = 'DropDownList'
$sdMel.Items.AddRange(@('Мягкий колокольчик','Тихий гонг','Двойной сигнал','Свой файл или ссылка (музыка)...')); $sdMel.SelectedIndex = 0
$sdMelTest = New-Ctl System.Windows.Forms.Button 311 186 84 28 'Слушать'
$sdFile = New-Ctl System.Windows.Forms.TextBox 15 222 290 24
$sdBrowse = New-Ctl System.Windows.Forms.Button 311 220 84 28 'Обзор...'
$sdNote = New-Ctl System.Windows.Forms.Label 15 260 380 134 'Действие: в указанное время начнётся отсчёт с предупреждением. Будильник: ПК проснётся из сна или гибернации. Из выключенного состояния он не включит ПК. В электропитании разрешите таймеры пробуждения. Разовые задания удаляются автоматически после срабатывания.'
$sdAdd = New-Ctl System.Windows.Forms.Button 15 400 380 34 'Добавить задание'
$sdG.Controls.AddRange(@($sdType,$sdT1,$sdTime,$sdOnce,$sdT2,$sdDelay,$sdT2b,$sdLead,$sdT3,$sdMel,$sdMelTest,$sdFile,$sdBrowse,$sdNote,$sdAdd))
$sdDiag = New-Ctl System.Windows.Forms.Button 15 628 200 32 'Проверить пробуждение'
$sdFix = New-Ctl System.Windows.Forms.Button 225 628 200 32 'Включить таймеры пробуждения'
$sd.Controls.AddRange(@($sdL,$sdList,$sdDel,$sdG,$sdDiag,$sdFix))

$schedJob = {
    $r = @()
    try { Import-Module ScheduledTasks -ErrorAction Stop } catch {}
    foreach ($x in @(Get-ScheduledTask -TaskName 'ONOFFTimer_*' -ErrorAction SilentlyContinue)) {
        $i = Get-ScheduledTaskInfo -InputObject $x -ErrorAction SilentlyContinue
        if ($i -and $x.State -ne 'Running' -and (-not $i.NextRunTime -or $i.NextRunTime.Year -lt 2000)) {
            Unregister-ScheduledTask -TaskName $x.TaskName -Confirm:$false -ErrorAction SilentlyContinue; continue
        }
        $r += [pscustomobject]@{ Name = $x.TaskName; Desc = [string]$x.Description }
    }
    $r
}
$script:schedBusy = $false; $script:schedTasks = @()
$schedPoll = New-Object System.Windows.Forms.Timer; $schedPoll.Interval = 200
$schedPoll.Add_Tick({
    if (-not $script:schedH.IsCompleted) { return }
    $schedPoll.Stop()
    try { $res = @($script:schedPs.EndInvoke($script:schedH)) } catch { $res = @() }
    $script:schedPs.Dispose(); $script:schedBusy = $false
    $script:schedTasks = $res; $sdList.Items.Clear()
    foreach ($x in $res) { [void]$sdList.Items.Add($x.Desc) }
})
function Update-Sched {
    if ($script:schedBusy) { return }
    $script:schedBusy = $true; $sdList.Items.Clear(); [void]$sdList.Items.Add('Загрузка...')
    $script:schedPs = [powershell]::Create(); [void]$script:schedPs.AddScript($schedJob.ToString())
    $script:schedH = $script:schedPs.BeginInvoke(); $schedPoll.Start()
}
function Remove-DoneTasks { Update-Sched }
function Update-SdState {
    $al = ($sdType.SelectedIndex -eq 7); $sdT2.Visible = -not $al; $sdDelay.Visible = -not $al; $sdT2b.Visible = $al; $sdLead.Visible = $al
    foreach ($c in $sdDays) { $c.Enabled = -not $sdOnce.Checked }
    $f = ($sdMel.SelectedIndex -eq 3); $sdFile.Enabled = $f; $sdBrowse.Enabled = $f
}
Update-SdState
$sdType.Add_SelectedIndexChanged({ Update-SdState }); $sdMel.Add_SelectedIndexChanged({ if ($sdType.SelectedIndex -ne 7) { $sdType.SelectedIndex = 7 }; Update-SdState }); $sdMelTest.Add_Click({ $m = $sdMel.SelectedIndex; if ($m -lt 3) { Play-Alert ($m + 1) } }); $sdOnce.Add_CheckedChanged({ Update-SdState })
$sdBrowse.Add_Click({ $o = New-Object System.Windows.Forms.OpenFileDialog; $o.Filter = 'Все файлы|*.*'; if ($o.ShowDialog() -eq 'OK') { $sdFile.Text = $o.FileName } })
$sdDel.Add_Click({
    $i = $sdList.SelectedIndex
    if ($i -ge 0 -and $i -lt @($script:schedTasks).Count) { try { Unregister-ScheduledTask -TaskName $script:schedTasks[$i].Name -Confirm:$false; Update-Sched } catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Расписание') } }
})
$sdAdd.Add_Click({
    try {
        $days = @(); $dn = @()
        for ($i = 0; $i -lt 7; $i++) { if ($sdDays[$i].Checked) { $days += $dow[$i]; $dn += $dshort[$i] } }
        $once = $sdOnce.Checked
        if (-not $once -and $days.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Выберите хотя бы один день.', 'Расписание'); return }
        $ti = $sdType.SelectedIndex; $tm = [datetime]::Today.Add($sdTime.Value.TimeOfDay); $lead = $(if ($ti -eq 7) { [int]$sdLead.Value } else { 0 })
        if ($ti -eq 7) {
            $mi = $sdMel.SelectedIndex; $f = $sdFile.Text.Trim()
            $arg = '-Alarm {0} -AlarmAt {1}' -f $(if ($mi -eq 3) { 0 } else { $mi + 1 }), $tm.ToString('HH:mm')
            if ($mi -eq 3) {
                if (-not $f) { [void][System.Windows.Forms.MessageBox]::Show('Укажите файл или ссылку.', 'Расписание'); return }
                $arg += (' -AlarmFile "{0}"' -f $f)
                $label = 'Будильник: ' + $(if ($f.Length -gt 28) { '...' + $f.Substring($f.Length - 28) } else { $f })
            } else { $label = 'Будильник: ' + $sdMel.SelectedItem }
        } else {
            $arg = '-AutoAction {0} -AutoDelay {1}' -f $ti, [int]$sdDelay.Value
            $label = $actions[$ti]
        }
        $ln = Get-Launch $arg; $act = New-ScheduledTaskAction -Execute $ln[0] -Argument $ln[1]
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 12)
        if ($ti -eq 7) { $set.WakeToRun = $true }
        if ($once) {
            $at = $tm; if ($at -le (Get-Date)) { $at = $at.AddDays(1) }
            $ta = $at.AddMinutes(-$lead); if ($ta -le (Get-Date).AddMinutes(1)) { $ta = (Get-Date).AddMinutes(1) }
            $trg = New-ScheduledTaskTrigger -Once -At $ta; $trg.EndBoundary = $at.AddMinutes(2).ToString('s'); $set.DeleteExpiredTaskAfter = 'PT1M'
            $when = 'один раз {0:dd.MM}' -f $at
        } else {
            $tt = $tm.AddMinutes(-$lead)
            if ($tt.Date -lt $tm.Date) { $days = @($days | ForEach-Object { $dow[([array]::IndexOf($dow, $_) + 6) % 7] }) }
            $trg = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $days -At $tt; $when = $dn -join ' '
        }
        $pr = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive
        $desc = '{0} | {1} | {2:HH:mm}' -f $label, $when, $tm
        Register-ScheduledTask -TaskName ('ONOFFTimer_' + [guid]::NewGuid().ToString('N').Substring(0, 8)) -Action $act -Trigger $trg -Settings $set -Principal $pr -Description $desc -Force | Out-Null
        Update-Sched
    } catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Расписание') }
})
$wakeGuid = 'BD3B718A-0680-4D9D-8AB2-E1D2B4AC806D'
function Get-WakeVals {
    try {
        $o = (& powercfg.exe /q SCHEME_CURRENT SUB_SLEEP $wakeGuid 2>&1) | Out-String
        $m = [regex]::Matches($o, '0x[0-9a-fA-F]{8}')
        if ($m.Count -ge 2) { return @([Convert]::ToInt32($m[$m.Count - 2].Value, 16), [Convert]::ToInt32($m[$m.Count - 1].Value, 16)) }
    } catch {}
    return $null
}
function Get-WakeName($v) { switch ($v) { 0 { 'отключены' } 1 { 'включены' } 2 { 'только важные' } default { 'неизвестно' } } }
$sdDiag.Add_Click({
    $v = Get-WakeVals; $nl = "`r`n"
    $t = 'Таймеры пробуждения в схеме электропитания:' + $nl
    if ($v) { $t += ('  от сети: ' + (Get-WakeName $v[0])) + $nl + ('  от батареи: ' + (Get-WakeName $v[1])) + $nl } else { $t += '  не удалось определить' + $nl }
    $na = @($script:schedTasks | Where-Object { $_.Desc -like 'Будильник*' }).Count
    $t += $nl + 'Заданий-будильников: ' + $na + $nl
    try { $lw = ((& powercfg.exe /lastwake 2>&1) | Out-String).Trim(); if ($lw.Length -gt 600) { $lw = $lw.Substring(0, 600) + '...' }; $t += $nl + 'Последнее пробуждение (powercfg /lastwake):' + $nl + $lw + $nl } catch {}
    $t += $nl + 'Если таймеры отключены, нажмите «Включить таймеры пробуждения». Из полного выключения компьютер не включить: используйте сон или гибернацию.'
    [void][System.Windows.Forms.MessageBox]::Show($t, 'Проверка пробуждения')
})
$sdFix.Add_Click({
    if ([System.Windows.Forms.MessageBox]::Show('Включить таймеры пробуждения в текущей схеме электропитания (от сети и от батареи)? Компьютеру будет разрешено просыпаться по таймеру.', 'ON/OFF Timer', 'YesNo', 'Question') -ne 'Yes') { return }
    try {
        & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_SLEEP $wakeGuid 1 | Out-Null
        & powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_SLEEP $wakeGuid 1 | Out-Null
        & powercfg.exe /setactive SCHEME_CURRENT | Out-Null
        $v = Get-WakeVals
        $r = $(if ($v -and $v[0] -eq 1 -and $v[1] -eq 1) { 'Готово: таймеры пробуждения включены.' } else { 'Команда выполнена, но проверка не подтвердила изменение. Включите вручную: Панель управления - Электропитание - Настройка схемы - Изменить дополнительные параметры - Сон - Разрешить таймеры пробуждения - Включить.' })
        [void][System.Windows.Forms.MessageBox]::Show($r, 'ON/OFF Timer')
    } catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'ON/OFF Timer') }
})
$btnSched.Add_Click({
    $wa = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $x = $form.Right + 8
    if ($x + $sd.Width -gt $wa.Right) { $x = [math]::Max($wa.Left, $form.Left - $sd.Width - 8) }
    $y = [math]::Max($wa.Top, [math]::Min($form.Top, $wa.Bottom - $sd.Height))
    $sd.StartPosition = 'Manual'; $sd.Location = New-Object System.Drawing.Point($x, $y); $sd.TopMost = $form.TopMost
    Update-Sched; [void]$sd.ShowDialog($form)
})
if ([Environment]::OSVersion.Version -lt [Version]'6.2') { $btnSched.Enabled = $false; $btnSched.Text = 'Расписание: нужна Windows 8 или новее' }

# ---------- События ----------
$btnGo.Add_Click({ if ($script:running) { Stop-Timer } else { Start-Timer } })
$btnTest.Add_Click({ Play-Alert })
$cbSound.Add_SelectedIndexChanged({
    if ($cbSound.SelectedIndex -eq 6) {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog; $dlg.Filter = 'Звук WAV|*.wav'
        if ($dlg.ShowDialog() -eq 'OK') { $cfg.SoundFile = $dlg.FileName } else { $cbSound.SelectedIndex = 1 }
    }
})
$btn5.Add_Click({ Add-Minutes 5 }); $btn15.Add_Click({ Add-Minutes 15 })
$m15.Add_Click({ Add-Minutes 15 }); $mStop.Add_Click({ Stop-Timer }); $mOpen.Add_Click({ Show-Main }); $mLnk.Add_Click({ New-DesktopShortcut $true })
$tray.Add_DoubleClick({ Show-Main })
$chkTop.Add_CheckedChanged({ $form.TopMost = $chkTop.Checked })
$chkForce.Add_CheckedChanged({ $cfg.Force = $chkForce.Checked })
$chkAuto.Add_CheckedChanged({
    try {
        if ($chkAuto.Checked) { $ln = Get-Launch ''; Set-ItemProperty $runKey -Name ONOFFTimer -Value $(if ($script:exeMode) { '"' + $ln[0] + '" ' + $ln[1] } else { $ln[0] + ' ' + $ln[1] }) }
        else { Remove-ItemProperty $runKey -Name ONOFFTimer -ErrorAction SilentlyContinue }
    } catch {}
})
$form.Add_Resize({ if ($form.WindowState -eq 'Minimized' -and $chkTray.Checked) { $form.Hide() } })

function Exit-App {
    if ($script:running) {
        if ([System.Windows.Forms.MessageBox]::Show('Таймер запущен. Выйти и отменить его?','ON/OFF Timer','YesNo','Question') -ne 'Yes') { return }
    }
    $script:exiting = $true; Save-Cfg; Close-Warn; $tray.Visible = $false; $tray.Dispose(); [System.Windows.Forms.Application]::Exit()
}
$mExit.Add_Click({ Exit-App })
$form.Add_FormClosing({
    param($s, $e)
    if (-not $script:exiting -and $chkTray.Checked -and $e.CloseReason -eq 'UserClosing') {
        $e.Cancel = $true; $form.Hide(); $tray.ShowBalloonTip(2000, 'ON/OFF Timer', 'Работает в трее. Выход: правый клик по значку.', 'Info'); return
    }
    if (-not $script:exiting) { Save-Cfg }
})
$form.Add_Shown({
    if (-not $script:auto -and -not $script:alarmMode -and -not $script:Minimized -and -not $cfg.LnkAsked) {
        $cfg.LnkAsked = $true; Save-Cfg
        if ([System.Windows.Forms.MessageBox]::Show('Создать ярлык ON/OFF Timer со значком на рабочем столе?', 'ON/OFF Timer', 'YesNo', 'Question') -eq 'Yes') { New-DesktopShortcut $false }
    }
    if ($script:Minimized -or $script:auto -or $script:alarmMode) { $form.Hide() }
    if ($script:alarmMode) { Start-AlarmMode }
    if ($script:auto) { $cbAct.SelectedIndex = $script:AutoAction; Start-Timer $script:AutoDelay }
})

$cleanTimer = New-Object System.Windows.Forms.Timer; $cleanTimer.Interval = 600000; $cleanTimer.Add_Tick({ Remove-DoneTasks })
if (-not $script:auto -and -not $script:alarmMode) { $cleanTimer.Start(); Remove-DoneTasks }
[System.Windows.Forms.Application]::Run($form)
