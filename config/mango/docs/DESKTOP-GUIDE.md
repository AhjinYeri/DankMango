# This desktop, in plain English

You are running **MangoWM** (the thing that draws and arranges windows) with
**DankMaterialShell**, usually shortened to **DMS** (the bar, the menus, the
notifications, the settings). Two separate programs, cooperating.

Press **SUPER+SHIFT+/** any time to get back to this hub. SUPER is the Windows key.

---

## The one big difference from Windows

Windows gives you a blank desktop and you drag windows around on it. This desktop
**tiles**: open one window and it fills the screen, open a second and the space
splits between them. You do not drag windows into place, and there is nothing to
maximise, because windows are already using all the space there is.

That is the whole adjustment. Everything below follows from it.

If you want a window to behave the Windows way — free-floating, draggable,
resizable — press **SUPER+v**. That takes it out of the tiling layout. Press it
again to put it back.

---

## Where your windows live

Instead of one desktop, there are nine, called **workspaces** (mango calls them
tags). **SUPER+1** through **SUPER+9** switch between them. **SUPER+SHIFT+1..9**
picks up the current window, moves it to that workspace, and takes you with it.

This replaces minimising. On Windows you minimise things to get them out of the
way; here you put them on a different workspace. Browser on 1, chat on 2, game on
3, and you flick between them.

Lost track of what is open? **SUPER+ALT+Tab** zooms out and shows every window at
once, scaled down, so you can see everything and click the one you want. That is
this desktop's Task View.

**ALT+Tab** works the way you already expect, with a pop-up preview.

---

## Finding and starting things

- **SUPER** on its own, tapped and released — the launcher. Start typing.
- **SUPER+space** — the same launcher, if the tap does not suit you.
- **SUPER+CTRL+Return** — search, for finding things beyond just apps.

The three you will use constantly: **SUPER+Return** (terminal), **SUPER+e**
(file manager), **SUPER+b** (browser).

---

## The bar

Along the top. Click things on it — most of it is interactive.

- **SUPER+n** — notifications you missed.
- **SUPER+c** — clipboard history. Everything you have copied recently, searchable.
  This has no Windows equivalent worth comparing to and it is one of the best
  things here.
- **SUPER+m** — running programs and what they are using. Task Manager.
- **SUPER+s** — settings: appearance, sound, displays, bar layout, plugins.
- **SUPER+SHIFT+q** — power menu: shut down, restart, log out, suspend.

---

## Making it yours

Change the wallpaper with **SUPER+w** and the entire desktop recolours to match
it — bar, menus, window borders, even the login screen. That is not a theme you
picked, it is generated from the image every time.

---

## When something looks wrong

**SUPER+r** re-reads the config file. It is the first thing to try, it is
instant, and it will not disturb your open windows.

All of the keyboard shortcuts live in `~/.config/mango/config.conf`, each with a
plain-English comment directly above it. Those comments are not decoration — they
are what the SUPER+/ cheatsheet and this hub both display. Edit a comment there
and it changes everywhere. Add a new shortcut without a comment and it shows up
as a raw command that means nothing to anyone.

One trap worth knowing: the comment must be on the line **above** the shortcut,
never on the end of it. mango only ignores lines that *start* with `#`, so a
trailing comment gets passed to the program as arguments and quietly breaks the
shortcut.

---

## Getting the full list

This hub shows a curated shortlist — the shortcuts worth knowing first. There are
more. **SUPER+/** opens the complete searchable cheatsheet, generated from the
config file, and you can filter it by typing.
