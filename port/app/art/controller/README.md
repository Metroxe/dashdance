# GameCube controller artwork

`gamecube_indigo.svg` is the indigo GameCube controller from [ControllerOverlays](https://github.com/datkat21/ControllerOverlays)
by Kat21 (datkat21), licensed under the GNU General Public License v3.0. The PNG layers next to it are rendered
from that file, unchanged except for being split into layers so the app can light up buttons and move the sticks:

| File | Contents |
|---|---|
| `gc_l.png`, `gc_r.png`, `gc_z.png` | The shoulder buttons, drawn under the body and tinted when pressed |
| `gc_body.png` | Everything else except the two stick caps |
| `gc_stick.png`, `gc_cstick.png` | The control stick and C-stick caps, moved with the live stick position |

All the layers share the SVG's canvas (3828 x 2689 units, rendered at 1600 px wide), so they stack without offsets. The
controller editors (`port/runtime/host/gc_diagram.cpp`) place their highlights using coordinates measured in those units.
Because this artwork is GPL-3.0, builds that include it are distributed under GPL-3.0 (the rest of Dashdance is
GPL-2.0-or-later, which allows that).
