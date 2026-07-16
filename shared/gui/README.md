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

## Boot modes

The image boots **headless by default** — the systemd default target is pinned
to `multi-user.target`, so a plain boot starts no desktop process and pays no
desktop RAM. A consumer activates graphics per boot, in one of two ways:

| Mode | Activation (in-guest, root) | What appears |
|---|---|---|
| headless | nothing | no desktop processes; the image behaves like the non-GUI build |
| vnc | `systemctl start tart-stacks-vnc.service` | a full desktop session on display `:1`, served on **`127.0.0.1:5901`** |
| window | `systemctl isolate graphical.target` | the display manager autologs the dev user into a desktop on the VM's virtual console |

Both activations are per-boot (nothing is persisted); a consumer that wants a
desktop on every boot can `systemctl enable tart-stacks-vnc.service` or
`systemctl set-default graphical.target` — the image deliberately ships with
neither.

`tart-up` owns the launcher side of these boot modes. Select one boot with
`tart-up --gui=vnc|window <vm>`, or give the VM an exact-name, single-winner
line in `~/.config/tart-stacks/gui` (`<bare-vm-name> headless|vnc|window`).
The file fails closed on malformed or duplicate entries; an absent line means
headless. Every `tart-up` path honors it, including the `ssh tart-<vm>`
auto-start and `tart-supervise` restarts. An engine such as workbench renders
this file from its own config.

**Window mode needs a windowed launch.** `tart-up --gui=window` omits
`--no-graphics`, then drives the in-guest activation. Closing the VM window
kills the VM. Opening one also needs a GUI login session, so a
`tart-supervise` daemon context may be unable to open it; stop the VM and start
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

## Support matrix

`DE` must be a line in `shared/desktops`; the layer is Xvnc-based, so a cell
needs its DE to ship an X11 session — a cell that doesn't **fails loud at
build time** (preflight or the post-install session assert), it never bakes a
desktop that can't start.

| DE | fedora | ubuntu | debian | X session (`/usr/share/xsessions/`) |
|---|---|---|---|---|
| `kde` (default) | ✅ image verified | ✅ layer verified | ❌ unsupported — Plasma 6 on Debian 13 is Wayland-only | `plasmax11` (Plasma 6) / `plasma` (Plasma 5) |
| `gnome` | ⚠️ built to contract, not live-verified | ⚠️ | ⚠️ | `gnome-xorg` / `gnome` |
| `xfce` | ⚠️ | ⚠️ | ⚠️ | `xfce` |

✅ image verified = a full `GUI=1` image build was booted and the whole
contract exercised (VNC session over an SSH tunnel, loopback-only bind,
parallel SSH, egress posture). ✅ layer verified = the provisioning layer was
exercised on a live VM of that distro (VNC session up, loopback bind,
NetworkManager pinned unmanaged), without a full image build. ⚠️ = package
sets and session names were verified against the live distro repos, but no
end-to-end boot has been run — the build's own asserts are the gate.
Re-verify a cell after building it the first time.

## Sizing

A DE adds roughly 1.5–2.5 GB to the image and ~1 GB RAM to a boot that
activates it. Give GUI clones headroom: `tart-new <name> <stack> <distro>`
resources or `tart set` (`--memory 8192` is comfortable for KDE).
