# Setting the view-only password on a register (UltraVNC Server)

With a view-only password set, "View only" in the launcher can connect without asking each time. "Interact" still uses the full password.

**The easy way (on each register):**
1. Right-click the UltraVNC eye icon by the clock and choose **Admin Properties**. On newer versions, run **UltraVNC Settings** (uvnc_settings.exe) as administrator.
2. Fill in **View-Only Password**. Keep it different from the full **VNC Password**: if the two are the same, every connection becomes view-only.
3. Click **Apply** and **OK**. Only the first 8 characters count.

**Command line (as administrator):** `setpasswd.exe <full-password> <view-only-password>` in the UltraVNC folder.

**In the file:** `ultravnc.ini` in the UltraVNC folder, section `[ultravnc]`: `passwd=` is the full-control password and `passwd2=` is the view-only one, both stored scrambled. Don't type plain passwords there; use the tools above.

**In the launcher:** the first time you press View only, it asks for the view-only password once (or choose "No password"). Change or clear it later in Setup > **View-only register password...** (right-click the launcher, then Setup). If View only can't connect with the saved password, the picker's status line points you there.

Sources: https://uvnc.com/docs/ultravnc-server/69-ultravnc-ini.html (passwd / passwd2, "Never use both same password"), https://forum.ultravnc.net/viewtopic.php?t=31302 (setpasswd.exe syntax, run as admin), https://support.moonpoint.com/os/windows/software/remote-control/vnc/ultravnc/change_password/ (Admin Properties > View-Only Password, first 8 characters).
