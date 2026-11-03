"""About Big Storage Rescue: what it does, who made it, where to ask."""

from gi.repository import Adw, Gtk

from .common import ISSUES, WEBSITE, _, version

# Names as their owners write them (escaped: the code itself stays in English letters)
DEVELOPERS = [
    "Bruno Gon\u00e7alves <bigbruno@gmail.com>",
    "Rafael Ruscher <rruscher@gmail.com>",
]


def comments():
    return "\n".join([
        _("Big Storage Rescue takes care of the drives of your computer:"),
        "",
        "• " + _("shows every drive and device, also the ones that are not mounted;"),
        "• " + _("explains why a device cannot be written to, and fixes it when that is safe;"),
        "• " + _("shows which programs keep a device busy, and removes it safely without forcing anything;"),
        "• " + _("tells how each drive is doing in one word (Critical, Poor, Good or Healthy) from SMART, "
                 "errors, age and temperature, and warns when a drive with problems is mounted;"),
        "• " + _("rescues files from a failing disk: copies them with real progress, resumes after a power cut, "
                 "makes disk images and finds lost partitions."),
        "",
        _("Made for BigLinux. It also works on other desktops, and every tool works in the terminal: big-storage-rescue --cli"),
    ])


def create_about():
    about = Adw.AboutDialog(application_name="Big Storage Rescue", application_icon="big-storage-rescue",
                            developer_name="BigLinux Team", version=version(),
                            website=WEBSITE, issue_url=ISSUES,
                            copyright="© 2026 BigLinux Team", license_type=Gtk.License.GPL_3_0,
                            comments=comments())
    about.set_developers(DEVELOPERS)
    return about
