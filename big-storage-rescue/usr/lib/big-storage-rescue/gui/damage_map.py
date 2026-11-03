"""The map of a disk image: what GNU ddrescue has read, could not read, left to
retry or not reached yet. The engine reduces its map to a fixed number of cells
(`--cli map ID --json`), so a disk of any size is the same small drawing: one
rectangle per cell, never one object per sector.

Colour is never the only sign: a cell that could not be read carries a cross,
one left to retry a dot, a cell read in part is filled in part, and the same
facts are said in words, also to a screen reader."""

import math

from gi.repository import Adw, Gtk

from . import widgets as w
from .common import _, human_size

COLUMNS = 64
GAP = 1
# At most this many pixels a cell; in a narrow window the grid takes fewer
# columns before a cell gets smaller than CELL_MIN, so its cross or dot stays
CELL_MAX = 10
CELL_MIN = 6
# Read, could not be read, to be retried, not read yet: the libadwaita palette,
# light and dark
PALETTE = {
    False: {"+": (0.15, 0.64, 0.41), "-": (0.75, 0.11, 0.16), "/": (0.80, 0.58, 0.04), "?": (0.0, 0.0, 0.0, 0.10), "mark": (1, 1, 1)},
    True: {"+": (0.18, 0.76, 0.49), "-": (0.88, 0.11, 0.14), "/": (0.90, 0.65, 0.04), "?": (1.0, 1.0, 1.0, 0.12), "mark": (0, 0, 0)},
}


class DamageMap(Gtk.Box):
    def __init__(self):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        self.cells = ""
        self.read = ""
        self.width = 0
        self.area = Gtk.DrawingArea(hexpand=True, accessible_role=Gtk.AccessibleRole.IMG)
        self.area.set_content_height(80)
        self.area.set_draw_func(self._draw)
        self.area.connect("resize", self._on_resize)
        self.append(self.area)
        self.summary = w.label("", css=("caption",))
        self.append(self.summary)
        legend = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, column_spacing=12, row_spacing=4, max_children_per_line=4)
        self.legend = {}
        self.swatches = []
        for key, text in (("+", _("Read")), ("/", _("Hard to read, to be retried")), ("-", _("Could not be read")), ("?", _("Not read yet"))):
            swatch = Gtk.DrawingArea(content_width=14, content_height=14, accessible_role=Gtk.AccessibleRole.PRESENTATION)
            swatch.set_draw_func(self._draw_swatch, key)
            self.swatches.append(swatch)
            caption = w.label(text, css=("caption", "dim-label"), wrap=False)
            item = w.hbox(6)
            item.append(swatch)
            item.append(caption)
            self.legend[key] = caption
            legend.append(item)
        self.append(legend)
        Adw.StyleManager.get_default().connect("notify::dark", lambda *_a: self.queue_draw_all())

    def queue_draw_all(self):
        for area in (self.area, *self.swatches):
            area.queue_draw()

    def set_map(self, data):
        """DATA: what `--cli map ID --json` answers."""
        self.cells = data.get("cells") or ""
        self.read = data.get("read") or ""
        size = data.get("size") or 0
        self.set_visible(bool(self.cells) and size > 0)
        if not self.cells or not size:
            return
        amounts = {"+": data.get("rescued", 0), "-": data.get("bad", 0), "/": data.get("slow", 0), "?": data.get("untried", 0)}
        names = {"+": _("Read"), "/": _("Hard to read, to be retried"), "-": _("Could not be read"), "?": _("Not read yet")}
        for key, caption in self.legend.items():
            caption.set_text(f"{names[key]}: {human_size(amounts[key])}")
        text = _("Read: %(read)s of %(size)s. Could not be read: %(bad)s. Still to read or retry: %(left)s.") % {
            "read": human_size(amounts["+"]), "size": human_size(size), "bad": human_size(amounts["-"]),
            "left": human_size(amounts["/"] + amounts["?"])}
        self.summary.set_text(text)
        self.area.update_property([Gtk.AccessibleProperty.LABEL], [_("Map of the disk") + ". " + text])
        self._fit_height()
        self.area.queue_draw()

    def _on_resize(self, _area, width, _height):
        if width != self.width:
            self.width = width
            self._fit_height()

    def _fit_height(self):
        """The height follows the grid: before the first allocation, as wide as it can be."""
        columns, size = self._grid(self.width) if self.width else (COLUMNS, CELL_MAX)
        height = math.ceil(len(self.cells) / columns) * (size + GAP) if self.cells else 80
        if self.area.get_content_height() != math.ceil(height):
            self.area.set_content_height(math.ceil(height))

    def _grid(self, width):
        """Columns and cell size for WIDTH pixels."""
        columns = max(1, min(COLUMNS, int((width + GAP) // (CELL_MIN + GAP))))
        return columns, max(2.0, min(CELL_MAX, (width - GAP * (columns - 1)) / columns))

    def _rgba(self, cr, key):
        color = PALETTE[Adw.StyleManager.get_default().get_dark()][key]
        cr.set_source_rgba(*color, *(() if len(color) == 4 else (1.0,)))

    def _draw(self, _area, cr, width, _height):
        if not self.cells:
            return
        columns, size = self._grid(width)
        for i, status in enumerate(self.cells):
            x = (i % columns) * (size + GAP)
            y = (i // columns) * (size + GAP)
            self._paint(cr, x, y, size, status, self.read[i] if i < len(self.read) else "0")

    def _paint(self, cr, x, y, size, status, read):
        self._rgba(cr, "?")
        cr.rectangle(x, y, size, size)
        cr.fill()
        if status == "+":
            self._rgba(cr, "+")
            cr.rectangle(x, y, size, size)
            cr.fill()
            return
        # Read in part: filled from the bottom, as much as was read; the rest
        # takes the colour of what it is
        part = size * max(0, "0123456789A".find(read)) / 10
        if part:
            self._rgba(cr, "+")
            cr.rectangle(x, y + size - part, size, part)
            cr.fill()
        if status in ("-", "/"):
            self._rgba(cr, status)
            cr.rectangle(x, y, size, size - part)
            cr.fill()
            if size >= CELL_MIN:
                self._rgba(cr, "mark")
                cr.set_line_width(max(1.0, size / 8))
                if status == "-":
                    m = size * 0.25
                    cr.move_to(x + m, y + m)
                    cr.line_to(x + size - m, y + size - m)
                    cr.move_to(x + size - m, y + m)
                    cr.line_to(x + m, y + size - m)
                    cr.stroke()
                else:
                    cr.arc(x + size / 2, y + size / 2, size / 7, 0, 2 * math.pi)
                    cr.fill()

    def _draw_swatch(self, _area, cr, width, _height, key):
        self._paint(cr, 0, 0, width, key, "A" if key == "+" else "0")
