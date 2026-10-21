# dmgbuild settings (scripts/dmg.sh). dmgbuild writes the window layout into .DS_Store
# itself, so no Finder/AppleScript runs. `defines` comes from `-D app=<path to Tokei.app>`.
import os.path

app = defines["app"]  # noqa: F821
app_name = os.path.basename(app)

format = "ULFO"
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}

default_view = "icon-view"
show_toolbar = False
show_sidebar = False
show_status_bar = False
show_pathbar = False
window_rect = ((200, 120), (540, 360))
icon_size = 128
text_size = 13
icon_locations = {app_name: (140, 160), "Applications": (400, 160)}
