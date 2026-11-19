"""Repairing a memory card or a USB drive: the one page of the window that leads
to erasing a drive. It says so from the first line, shows what is on the drive
and offers to recover it first. The engine decides whether the drive can be
repaired at all (`repair --dry-run`); here the person chooses how, and confirms.
Writing is done by a helper of its own, after the administrator password."""

from gi.repository import Adw, GLib, Gtk

from .. import actions
from .. import widgets as w
from ..common import _, human_duration, human_size

# What the steps are, in the order they run. The job page shows the same ones.
STEPS = (
    ("capacity", lambda: _("Real capacity"),
     lambda: _("Finds counterfeit cards, which announce more space than they have."), "system-search-symbolic"),
    ("surface", lambda: _("Test of the surface"),
     lambda: _("Writes and reads back blocks across the drive, more at its end, where cheap cards fail first."), "view-grid-symbolic"),
    ("partition", lambda: _("New partition table"),
     lambda: _("One partition that leaves out what failed, with a margin before it."), "drive-multidisk-symbolic"),
    ("format", lambda: _("New filesystem"),
     lambda: _("Ready to use on this computer and on other devices."), "document-new-symbolic"),
)

FILESYSTEMS = (
    ("auto", lambda: _("Automatic"), lambda: _("FAT32 up to 32 GB, as cards are sold; exFAT for larger drives.")),
    ("fat32", lambda: _("FAT32"), lambda: _("Works everywhere: cameras, car radios, TVs, phones. Files up to 4 GB.")),
    ("exfat", lambda: _("exFAT"), lambda: _("Large files, on modern computers and phones. Some older devices do not read it.")),
    ("ext4", lambda: _("ext4"), lambda: _("For Linux only.")),
)

# Shown on the page itself: the danger notice already says the rest
QUIET_WARNINGS = {"has-data"}
PLAN_DELAY_MS = 350


class StepCard(Gtk.Box):
    """One step of a repair: its number, an icon, what it does."""

    def __init__(self, number, title, text, icon_name):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=6, css_classes=["card", "repair-step"])
        top = w.hbox(8)
        pill = w.label(str(number), css=("step-pill",), wrap=False, xalign=0.5)
        pill.set_valign(Gtk.Align.CENTER)
        top.append(pill)
        top.append(w.icon(icon_name, 20))
        self.append(top)
        heading = w.label(title, css=("heading",))
        caption = w.label(text, css=("caption", "dim-label"))
        # Narrow by nature: four of them fit side by side, and wrap on a phone
        heading.set_max_width_chars(18)
        caption.set_max_width_chars(22)
        self.append(heading)
        self.append(caption)
        self.update_property([Gtk.AccessibleProperty.LABEL], [f"{number}. {title}. {text}"])


class RepairPage(Adw.NavigationPage):
    def __init__(self, window, dev):
        super().__init__(title=_("Repair the drive"), tag="repair")
        self.window = window
        self.dev = dev
        self.plan = None
        self._plan_timer = 0
        self._asking = False
        self._again = False
        self._starting = False
        self._label_filled = False

        self.content = w.box(spacing=18)
        self.plan_box = w.box(spacing=12)
        self.start_btn = w.button(_("Repair and erase"), self._start, css=("destructive-action", "pill"), icon_name="media-flash-symbolic")
        self.start_btn.set_sensitive(False)
        self.confirm = Gtk.CheckButton()
        self.confirm.connect("toggled", lambda *_a: self._update_start())

        self._build()
        bar = Gtk.ActionBar()
        bar.pack_start(w.button(_("Cancel"), self._back))
        bar.pack_end(self.start_btn)
        tool = Adw.ToolbarView(content=w.page_scroller(self.content))
        tool.add_top_bar(Adw.HeaderBar())
        tool.add_bottom_bar(bar)
        self.set_child(tool)
        self.connect("hiding", lambda *_a: self._cancel_timer())
        self._ask_plan()

    # ----- the page
    def _build(self):
        dev = self.dev
        hero = w.hbox(16)
        image = w.icon(dev.symbolic_icon, 48, css=("hero-icon",))
        image.set_valign(Gtk.Align.START)
        hero.append(image)
        names = w.box(spacing=4)
        names.set_hexpand(True)
        names.append(w.label(_("Repair “%s”") % dev.name, css=("title-2",)))
        names.append(w.label(" · ".join(x for x in (dev.kind_label, human_size(dev.size), dev.device) if x), css=("dim-label",)))
        names.append(w.LevelBadge(dev.health.level, dev.health.label))
        hero.append(names)
        self.content.append(hero)

        self.content.append(w.label(_("For a memory card or USB drive that gives write errors, shows the wrong size or cannot be formatted. "
                                      "It is tested, and set up again using only the part that works."), css=("title-4",)))

        # What is on the drive comes first: that is what the person risks
        self.content.append(self.plan_box)

        steps = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, column_spacing=10, row_spacing=10,
                            min_children_per_line=1, max_children_per_line=2, homogeneous=True)
        for number, (_key, title, text, icon_name) in enumerate(STEPS, 1):
            steps.append(StepCard(number, title(), text(), icon_name))
            steps.get_last_child().set_focusable(False)
        self.content.append(steps)

        options = w.Group(_("How"))
        self.quick_row = self._radio_row(_("Quick test"), _("Samples of the surface, more at the end of the drive. A few minutes."), None)
        self.full_row = self._radio_row(_("Complete test"), _("Every block is written and read back. Finds every bad area, and takes much longer."),
                                        self.quick_row.check)
        self.quick_row.check.set_active(True)
        options.add_row(self.quick_row)
        options.add_row(self.full_row)

        self.fs_row = Adw.ComboRow(title=_("Filesystem"), model=Gtk.StringList.new([title() for _k, title, _t in FILESYSTEMS]))
        self.fs_row.set_subtitle(FILESYSTEMS[0][2]())
        self.fs_row.set_subtitle_lines(0)
        self.fs_row.connect("notify::selected", self._fs_changed)
        options.add_row(self.fs_row)

        self.label_row = Adw.EntryRow(title=_("Name of the new volume"))
        self.label_row.connect("changed", lambda *_a: self._options_changed())
        options.add_row(self.label_row)

        advanced = Adw.ExpanderRow(title=_("Advanced"), subtitle=_("Space left unused at the end of the drive"))
        self.margin_row = Adw.SpinRow.new_with_range(0, 256, 1)
        self.margin_row.set_title(_("Margin before the end, in MiB"))
        self.margin_row.set_subtitle(_("Cheap cards often fail in their last megabytes. 8 MiB costs almost nothing."))
        self.margin_row.set_subtitle_lines(0)
        self.margin_row.set_value(8)
        self.margin_row.connect("notify::value", lambda *_a: self._options_changed())
        advanced.add_row(self.margin_row)
        options.add_row(advanced)
        self.content.append(options)

        self.name_hint = w.label("", css=("caption", "dim-label"))
        self.content.append(self.name_hint)

        confirm_box = w.box(spacing=8, css=("danger-panel",))
        confirm_box.append(w.label(_("This cannot be undone"), css=("title-3",)))
        confirm_box.append(w.label(_("The administrator password is asked before anything is written. The work goes on with this window closed, and its report stays in Copies and searches.")))
        self.confirm.set_child(w.label(_("I understand that everything on “%s” will be erased for good") % self.dev.name))
        confirm_box.append(self.confirm)
        self.content.append(confirm_box)

    def _radio_row(self, title, subtitle, group):
        row = w.row(title, subtitle, activatable=True)
        check = Gtk.CheckButton(valign=Gtk.Align.CENTER)
        if group:
            check.set_group(group)
        check.connect("toggled", lambda button: button.get_active() and self._options_changed())
        row.add_prefix(check)
        row.set_activatable_widget(check)
        row.check = check
        return row

    # ----- options
    @property
    def mode(self):
        return "full" if self.full_row.check.get_active() else "quick"

    @property
    def filesystem(self):
        return FILESYSTEMS[self.fs_row.get_selected()][0]

    def _fs_changed(self, *_a):
        self.fs_row.set_subtitle(FILESYSTEMS[self.fs_row.get_selected()][2]())
        self._options_changed()

    def _options_changed(self):
        self._cancel_timer()
        self._plan_timer = GLib.timeout_add(PLAN_DELAY_MS, self._plan_now)

    def _cancel_timer(self):
        if self._plan_timer:
            GLib.source_remove(self._plan_timer)
            self._plan_timer = 0

    def _plan_now(self):
        self._plan_timer = 0
        self._ask_plan()
        return False

    def devices_changed(self):
        """The drive may be gone, or its volumes mounted or unmounted meanwhile."""
        dev = self.window.device_by_id(self.dev.stable_id)
        if dev is None or dev.diskseq != self.dev.diskseq:
            self.dev = dev or self.dev
            self.plan = {"ok": False, "error_text": _("The drive was disconnected or replaced. Nothing was done.")}
            self._show_plan()
            return
        self.dev = dev
        self._ask_plan()

    # ----- what the engine says
    def _ask_plan(self):
        if self._asking:
            self._again = True
            return
        self._asking = True
        self.window.engine.repair(self._planned, self.dev.device, mode=self.mode, filesystem=self.filesystem,
                                  label=self.label_row.get_text().strip(), margin=int(self.margin_row.get_value()),
                                  diskseq=self.dev.diskseq, dry_run=True)

    def _planned(self, res):
        self._asking = False
        if self._again:
            self._again = False
            self._ask_plan()
            return
        self.plan = res.data if isinstance(res.data, dict) else {"ok": False, "error_text": res.message}
        self._show_plan()

    def _show_plan(self):
        box = self.plan_box
        w.clear(box)
        plan = self.plan or {}
        if not plan.get("ok"):
            text = plan.get("error_text") or _("The reason could not be determined.")
            missing = plan.get("missing") or []
            if missing:
                packages = " ".join(sorted({m.get("package", "") for m in missing if m.get("package")}))
                text += "\n" + _("Install: %s") % packages
            box.append(w.notice(text, "critical"))
            self.name_hint.set_text("")
            self._update_start()
            return

        if plan.get("has_data"):
            risky = any(x.get("key") == "risky" for x in plan.get("warnings") or [])
            text = _("Everything on this drive will be erased. If it holds files you need, recover them first.")
            if risky:
                text += " " + _("It reported problems: a repair erases its files for good.")
            box.append(w.notice(text,
                                "critical", action=_("Recover files first"), callback=lambda: self.window.open_wizard(self.dev)))
            group = w.Group(_("What will be erased"))
            for vol in plan.get("volumes") or []:
                title = vol.get("label") or vol.get("device", "").rsplit("/", 1)[-1]
                parts = [vol.get("fstype") or _("unknown"), human_size(vol.get("size"))]
                if vol.get("used") is not None:
                    parts.append(_("%s used") % human_size(vol["used"]))
                subtitle = " · ".join(p for p in parts if p)
                if vol.get("mountpoint"):
                    subtitle += "\n" + _("Mounted at %s: it is unmounted first.") % vol["mountpoint"]
                group.add_row(w.row(title, subtitle, icon_name="drive-harddisk-symbolic"))
            box.append(group)

        for warning in plan.get("warnings") or []:
            # The notice above already asks to recover files first
            if warning.get("key") in QUIET_WARNINGS or (warning.get("key") == "risky" and plan.get("has_data")):
                continue
            level = "critical" if warning.get("key") == "risky" else "attention"
            box.append(w.notice(warning.get("text", ""), level))

        if plan.get("size"):
            self.full_row.set_subtitle(_("Every block is written and read back. Finds every bad area. On a slow drive of this size, about %s.")
                                       % human_duration(self._full_estimate()))
        label = plan.get("label") or ""
        self.name_hint.set_text(_("The new volume will be called “%(name)s”, with %(fs)s.") % {"name": label, "fs": plan.get("filesystem", "").upper()}
                                if label else "")
        if not self._label_filled and label and not self.label_row.get_text():
            # The name the engine chose, ready to be changed
            self._label_filled = True
            self.label_row.set_text(label)
        self._update_start()

    def _full_estimate(self):
        size = (self.plan or {}).get("size") or self.dev.size or 0
        return 180 + size // 6000000 + size // 18000000

    def _update_start(self):
        ok = bool((self.plan or {}).get("ok")) and self.confirm.get_active() and not self._starting
        self.start_btn.set_sensitive(ok)

    # ----- starting
    def _back(self):
        self.window.close_repair()

    def _start(self):
        plan = self.plan or {}
        if not plan.get("ok") or not self.confirm.get_active() or self._starting:
            return
        if plan.get("mounted"):
            # Unmounted as anywhere else in the window: who keeps it busy is
            # shown, and nothing is forced. The repair starts once it is done
            actions.unmount(self.window, self.dev.device, then=self._go)
            return
        self._go()

    def _go(self):
        self._starting = True
        self.window.notify_text(_("Asking for the administrator password…"))

        def started(res):
            self._starting = False
            data = res.data if isinstance(res.data, dict) else {}
            if data.get("id"):
                self.window.refresh_jobs()
                self.window.open_job(data["id"], replace_top=True)
                return
            self._update_start()
            w.alert(self.window, _("The repair did not start"), data.get("error_text") or res.message)
        self.window.engine.repair(started, self.dev.device, mode=self.mode, filesystem=self.filesystem,
                                  label=self.label_row.get_text().strip(), margin=int(self.margin_row.get_value()),
                                  diskseq=self.dev.diskseq)
