# GUI layer — image contract

The optional desktop layer (`make build STACK=<stack> DISTRO=<distro> GUI=1 DE=<de>`)
bakes a desktop environment into any stack image at build time. This file is the
**contract between the image and whatever boots it** (a human, or an engine that
drives VMs): everything a consumer may rely on is listed here, and nothing else
about the desktop install is stable API. Provisioning lives in
`shared/scripts/gui.sh` + `shared/scripts/gui-lib.sh` — change them and this
file together.

## Identity

- **Image name:** `<distro>-<stack>-<de>` (e.g. `fedora-php-kde`). Non-GUI
  images keep `<distro>-<stack>`; flavors build side by side.
- **Manifest:** `/etc/tart-stacks-release` carries `gui: <de>` (`gui: none` on
  non-GUI images) — the machine-readable probe for "is a desktop baked, and
  which".

## What is installed

The desktop shell, its display manager, and a terminal — plus the minimum set of
applications that make the session usable rather than merely present: a **file
manager**, a GUI text editor, an archive handler, an image viewer, and a
screenshot tool where the DE ships none of its own. Each is the DE's own
application, so it inherits the session's theming and file associations. Nothing
beyond this is stable API: rely on the *capability*, never on a package name.

| DE | file manager | editor | archives | images | screenshots |
|---|---|---|---|---|---|
| `kde` | Dolphin | Kate | Ark | Gwenview | Spectacle |
| `gnome` | Nautilus | GNOME Text Editor | File Roller | Loupe | built into the Shell |
| `xfce` | Thunar | Mousepad | Xarchiver | Ristretto | xfce4-screenshooter |

Package names for these diverge across families in two places that read like
typos but are not: Fedora keeps Thunar's upstream capitalization (`Thunar`), and
the apt family namespaces Spectacle as `kde-spectacle`.

A conventional browser is a DE-independent, optional capability: Firefox on the
dnf family and Firefox ESR on the apt family where the distro publishes it.
Ubuntu's `firefox` deb is a snap transition stub and `firefox-esr` is absent, so
Ubuntu GUI images record `firefox-esr` under `skipped-optional-packages` in the
manifest instead of pulling snapd or failing the build. On dnf/GNOME the browser
arrives anyway as a weak dependency of the desktop set — the explicit row is
what guarantees one on KDE and XFCE, and on the apt family.

KDE's fresh-session panel pins the installed browser when present, then Dolphin,
Konsole, and Kate. Discover is deliberately absent: no software-center package
is installed, and its package operations are incompatible with confined guest
egress.

`spice-vdagent` is installed on every GUI image. It is what host↔guest clipboard
sharing depends on in a native VM window (`tart run --help` names the package).
Its udev rule starts the daemon only once the host exposes the channel device, so
a headless or VNC-only boot pays nothing for it; VNC carries its own clipboard
over RFB and does not use it.

## Boot modes

The image boots **headless by default** — the systemd default target is pinned
to `multi-user.target`, so a plain boot starts no desktop process and pays no
desktop RAM. A consumer activates graphics per boot, in one of two ways:

| Mode | Activation (in-guest) | What appears |
|---|---|---|
| headless | nothing | no desktop processes; the image behaves like the non-GUI build |
| vnc | `systemctl start tart-stacks-vnc.service` | a full desktop session on display `:1`, served on **`127.0.0.1:5901`** |
| window | apply the host backing scale as the dev user, then `systemctl isolate graphical.target` | the display manager autologs the dev user into a correctly scaled desktop on the VM's virtual console |

Both activations are per-boot (neither the unit nor default target is changed);
a consumer that wants a desktop on every boot can
`systemctl enable tart-stacks-vnc.service` or `systemctl set-default
graphical.target` — the image deliberately ships with neither. Window-scale
keys persist in the user's DE config, but `tart-up` reconciles them to the
detected factor before every window session it starts, including removing them
for factor 1.

`tart-up` owns the launcher side of these boot modes. Select one boot with
`tart-up --gui=vnc|window <vm>`, or give the VM an exact-name, single-winner
line in `~/.config/tart-stacks/gui` (`<bare-vm-name> headless|vnc|window`).
The file fails closed on malformed or duplicate entries; an absent line means
headless. Every `tart-up` path honors it, including the `ssh tart-<vm>`
auto-start. An engine such as workbench renders
this file from its own config.

**Window mode needs a windowed launch.** `tart-up --gui=window` omits
`--no-graphics`, then drives the in-guest activation. Closing the VM window
kills the VM. Opening one also needs a GUI login session, so a
daemon context may be unable to open it; stop the VM and start
it from a terminal to recover a visible window. VNC has no windowed-launch
dependency and stays behind the loopback-only SSH tunnel.

## The VNC surface

- **Unit:** `tart-stacks-vnc.service` — one stable name on every distro × DE;
  the body wraps the distro's packaged TigerVNC session starter
  (`vncsession` on dnf-family, `tigervncsession` on apt-family), which opens a
  real PAM/logind session for the dev user.
- **Display/port:** `:1` / TCP `5901`, bound to **loopback only**.
- **Auth:** none at the VNC level (`SecurityTypes=None`), **by design**: the
  server is unreachable from the network, so the SSH key is the auth — reach it
  through a tunnel (`ssh -L 5901:127.0.0.1:5901 tart-<vm>`, then point a VNC
  client at `localhost:5901`). No VNC password is baked because it would be a
  shared secret in every clone.
- **Geometry:** 1920×1080 default; TigerVNC honors client-side resize (RandR).
- **Session:** the DE's X11 session, from `/usr/share/xsessions/` (per-cell
  name in the support matrix below). Config lives in `~/.vnc/config`
  (dnf-family) / `~/.vnc/tigervnc.conf` (apt-family) and
  `/etc/tigervnc/vncserver.users` (`:1=admin`).

## The window surface

- **Display manager:** per-DE unit (kde → `sddm.service`, gnome →
  `gdm.service` / `gdm3.service` on apt, xfce → `lightdm.service`), enabled at
  build so the `display-manager.service` alias exists — `graphical.target`
  pulls it in; the `multi-user.target` default is what keeps it dormant.
- **Autologin is baked** for the dev user. Deliberate: `99-finalize.sh` locks
  the account password, so a greeter would be a dead end — and a console
  session grants nothing the authorized SSH key doesn't already (NOPASSWD
  sudo). Treat "can see the VM window" as "owns the VM".
- **Screen locking is disabled** (same locked-password reasoning), and the
  sleep/suspend/hibernate targets are masked — a suspended VM is a dead VM.
- **Geometry is a property of the VM, not of the session.** The virtual display
  is sized on the host (`tart set <vm> --display WIDTHxHEIGHT`); nothing inside
  the guest can raise it, so a VM left at Tart's 1024×768 default is stuck there.
  `tart-new` therefore sizes every GUI clone at create time (1920×1080, override
  with `--display`) and sets `--display-refit` so the guest follows the host
  window as it is resized **in host device pixels**. The 1920×1080 boot geometry
  deliberately remains a normal window size; it is not the host screen's full
  logical-point geometry. A VM created by other means gets the Tart default and
  needs an explicit `tart set`.
- **Desktop scale follows the main host display's backing scale.** The virtual
  connector reports no physical dimensions, so the guest cannot derive this
  value itself. On a window boot that `tart-up` starts, it divides the main
  display's native pixel width by its logical point width, validates an integer
  scale in the range 1–3, and invokes
  `/usr/local/bin/tart-stacks-display-scale <factor>` as the dev user **before**
  isolating `graphical.target`. This ordering makes the scale visible to the
  first desktop session. `TART_DISPLAY_SCALE=<integer>` forces the host value;
  non-integers warn and use 1, and values outside 1–3 are clamped with a
  warning. The probe runs before the window exists, so it can only read the
  *main* display: on a mixed-scale setup a window dragged to a display with a
  different backing scale is sized for the main one, and `TART_DISPLAY_SCALE`
  is the override for that. Scale-probe failures also yield 1, and a
  guest-application failure warns but does not block the VM or desktop.
- **The scale applier owns only each DE's scale keys.** KDE writes
  `forceFontDPI`, `ScaleFactor`, and `ScreenScaleFactors`; GNOME writes its
  interface window scale while keeping the independent text multiplier at its
  default; XFCE writes its GDK window scale and Xft DPI. Reapplying a different
  factor replaces those values, and factor 1 removes/resets them so a VM moved
  to a non-HiDPI host does not retain an earlier scale. It is a *pre-session*
  tool: a running desktop holds these values in memory and rewrites its own
  config on exit, so running it by hand inside a live session applies to the
  next session, and says so.

Scale detection is intentionally window-only. VNC has no host window whose
device-pixel framebuffer inherits a backing scale, so its 1920×1080/RandR
surface is left under the VNC client's control.

## Network posture — unchanged, on purpose

The desktop changes the display, **not** the network posture. Egress still
flows only through whatever the host enforces at VM start (e.g. softnet
`@host`-only confinement plus a host-side proxy); the image bakes nothing that
fights or bypasses it:

- VNC binds loopback only — no new listener on the VM's interface.
- On the apt family, NetworkManager (dragged in as a DE dependency) is pinned
  **unmanaged** for ethernet (`/etc/NetworkManager/conf.d/tart-stacks-unmanaged.conf`),
  so the base image's renderer keeps sole ownership of the primary interface —
  no second DHCP client, no route/DNS rewrites. On dnf-family NetworkManager
  already is the base's manager and is left alone.
- Broadcast/discovery daemons that ride in with a desktop (`avahi-daemon`,
  `cups-browsed`) are disabled.
- No firewall is added or reconfigured.

## Adding a desktop

The DE token is the axis this layer varies on, so a new one touches every
selector rather than a config file:

1. Add the token to `shared/desktops` (that is what `tart-new`, the Makefile's
   `check-de`, and the base-image guard read).
2. Add a row to the DE selectors in `shared/scripts/gui-lib.sh`. `gui_packages`,
   `gui_app_packages` and `gui_dm_unit` branch on family × DE, so each needs a
   dnf row and an apt row; `gui_scale_packages` and `gui_session_candidates`
   branch on the DE alone, so each needs one.
3. Add a `apply_<de>` branch to `shared/scripts/display-scale.sh`, using the
   desktop's own config tool. Scale is per-DE; there is no generic path.
4. If the desktop needs anything baked beyond packages (a panel layout, an
   autologin stanza), add it to the `case "$DE"` in `shared/scripts/gui.sh`.
5. Extend `test/gui-lib.sh` (the selectors are asserted in lockstep with
   `shared/desktops`, so an unlisted token fails there) and
   `test/display-scale.sh`.
6. Build the cell and add it to the matrix below with an honest status.

## Support matrix

`DE` must be a line in `shared/desktops`; the layer is Xvnc-based, so a cell
needs its DE to ship an X11 session — a cell that doesn't **fails loud at
build time** (preflight or the post-install session assert), it never bakes a
desktop that can't start.

| DE | fedora | ubuntu | debian | X session (`/usr/share/xsessions/`) |
|---|---|---|---|---|
| `kde` (default) | ✅ image verified | ✅ image verified | ✅ image verified | `plasmax11` (Plasma 6) / `plasma` (Plasma 5) |
| `gnome` | ✅ image verified | ✅ image verified | ✅ image verified | `gnome-xorg` / `gnome` |
| `xfce` | ✅ image verified | ✅ image verified | ✅ image verified | `xfce` |

✅ image verified = a full `GUI=1` build was booted and its desktop contract
asserted in a live session: the applied scale (`Xft.dpi` 96 → 192 → unscaled),
the manifest's baked `gui:` line, the browser — or, on ubuntu, the recorded
`firefox-esr` gap — and for KDE the panel's pinned launchers. ⚠️ = package sets
and session names were checked against the live distro repos, but no
end-to-end boot has been run — the build's own asserts are the gate.
Re-verify a cell after building it the first time, and after a change to the
contract it vouches for — a status earned before a new code path does not cover
it.

The ✅ deliberately does not span the network posture above. That is not a
per-cell property: the VNC bind is loopback-only by the session config this
layer installs, and `tart-up` fails closed on a non-loopback listener before
reporting the desktop ready — both covered by the test suite, on every cell at
once, rather than re-observed per distro.

A reset lands as either `Xft.dpi: 96` or no `Xft.dpi` resource at all, and both
are correct: resetting removes the override rather than writing a 1x value.
Which one a cell shows is a property of the distro's xfce packaging — debian
ships a populated `xsettings` channel whose packaged default republishes 96,
while on ubuntu that file does not exist until the applier creates it, so there
is nothing left to republish. Assert "unscaled", never the literal 96.

Known issue, ubuntu only: `xfconfd` writes its channel by truncating in place,
with no fsync and no atomic rename, and it outlives the VNC unit it served
(alive ~5 s after `systemctl stop`, gone by ~15 s). Powering the VM off inside
that window leaves `xsettings.xml` at zero bytes — reproduced 3/3 on ubuntu
(xfconf 4.18.1) and 0/3 on debian (4.20.0, which writes durably). The applier
treats an empty file as an absent one, so scaling still works and the file is
rebuilt on the next run; only settings made through the desktop's own tools are
lost. Waiting ~20 s between stopping the desktop and stopping the VM avoids it.

Every distro × DE cell is supported; there is no refused combination. The X
session assert above is the only gate, and it reads `/usr/share/xsessions/`
rather than package names — which is what a cell actually needs. Debian's
`plasma-workspace` ships no `plasma-x11-session` package but does ship
`plasmax11.desktop`, so a package-name probe refused a cell that builds and
boots. Add a distro or a DE and the assert covers it without a new special case.

## Sizing

A DE adds roughly 1.8–2.8 GB to the image (the browser alone is ~320 MB) and
~1 GB RAM to a boot that
activates it. Give GUI clones headroom: `tart-new <name> <stack> <distro>`
resources or `tart set` (`--memory 8192` is comfortable for KDE).
