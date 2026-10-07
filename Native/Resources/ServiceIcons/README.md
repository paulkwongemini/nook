# Nook icons

Nook's app icon and service icons are original SVG designs created for this project. They do not use Google product logos or third-party icon libraries.

| Resource | Design | Rendering |
| --- | --- | --- |
| `chat.svg` | Speech bubble | Monochrome template |
| `gmail.svg` | Envelope | Monochrome template |
| `drive.svg` | Folder | Monochrome template |
| `calendar.svg` | Calendar | Monochrome template |
| [`Resources/AppIcon.svg`](../../../Resources/AppIcon.svg) | Open corner mark on a plum background | Ivory and lilac shapes |

The sidebar order is Chat, Mail, Drive, and Calendar. The Mail button opens Gmail, and its resource files use the name `gmail`.

Service SVGs use a 24×24 canvas. They are converted to transparent 192×192 PNGs and displayed at 24×24 pt in the app. `NativeIcons` marks them as template images so macOS can tint them for light and dark appearance.

The 1024×1024 app icon SVG is converted to a macOS ICNS file containing multiple resolutions. Intermediate PNGs are created in a temporary directory and deleted afterward. The required ICNS and service PNGs are included in the repository, so normal app builds do not require image conversion tools.

## Regenerating icons

After editing the SVGs, run the following command from the repository root on macOS with `rsvg-convert` and `iconutil` available:

```sh
bash scripts/render-icons.sh
```

The script reads only local SVGs and does not download icons. Google service names identify what each button opens; they do not imply endorsement by or affiliation with Google. See the [README](../../../README.md) for the project's licensing status.
