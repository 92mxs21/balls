# balls

One-click Fabric + mod setup for **Minecraft 26.3**.

Drop `run.cmd` next to `install-mods.ps1` and `mods.json`, double-click, done.
Mods are resolved from the live Modrinth API at run time, so nothing is
pinned and nothing goes stale.

## Use

```
run.cmd
run.cmd -IncludeOptional
run.cmd -GameVersion 26.3 -MinecraftDir "D:\mc" -DryRun
```

| Flag | Effect |
| --- | --- |
| `-IncludeOptional` | Also install the mods marked `required: false` |
| `-DryRun` | Resolve and report, write nothing |
| `-ReinstallMods` | Re-download mods already present |
| `-ForceFabricInstall` | Run the Fabric installer even if a profile exists |
| `-GameVersion` | Target a version other than 26.3 |
| `-MinecraftDir` | Override the `.minecraft` root |
| `-ModsManifest` | Use a different mod list |

Mods land in the Fabric profile's `mods` folder, e.g.
`%APPDATA%\.minecraft\versions\fabric-loader-0.19.5-26.3\mods`.
Then pick the `fabric-loader-26.3` profile in the launcher.

## Default mod set

| Mod | Required | Purpose |
| --- | --- | --- |
| Sodium | yes | Rendering engine |
| Fabric API | yes | Core interop library |
| Lithium | yes | Gameplay optimisation |
| FerriteCore | yes | Memory optimisation |
| Iris | no | Shader support |
| Sodium Extra | no | Extra render options |
| Simple Voice Chat | no | Proximity voice |
| Dream Displays | no | Decoration blocks |

Edit `mods.json` to change the list. Add a `slug` from any Modrinth project
page and it will be picked up automatically.

## How the Fabric step works

If a Fabric profile for the target version already exists, the installer is
skipped entirely. Otherwise it downloads the current stable installer from
`meta.fabricmc.net`, launches it in your console, and watches the process.
Closing the installer early is fine, the script continues and re-checks
whether the profile appeared.

## Antivirus

Deliberately not evasive. No encoding, packing, or obfuscation. No Defender
exclusions, no AMSI tampering, no disabled services. Every download comes
over HTTPS from an official upstream API and is checked against the SHA-512
that Modrinth publishes.

`run.cmd` passes `-ExecutionPolicy Bypass` to PowerShell. That flag is
per-process, does not persist, and is the documented way to run a local
script. It is not an antivirus control. To skip it:

```
powershell -NoProfile -File .\install-mods.ps1
```

Not affiliated with Mojang, Microsoft, FabricMC, or Modrinth.
