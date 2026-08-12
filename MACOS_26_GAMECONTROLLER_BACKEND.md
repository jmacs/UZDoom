# macOS 26 GameController Backend

This branch adds an opt-in native macOS controller backend for the macOS 26
GameController.framework behavior. It is a small local workaround for
controllers that are not usable through the existing Cocoa/IOKit implementation.

The default Cocoa build is unchanged: it keeps the legacy IOKit controller
backend and a macOS 10.13 deployment target. Enable this backend only for a
macOS 26 build.

## What it does

When `OSX_GAMECONTROLLER_BACKEND=ON`, UZDoom uses
`GCExtendedGamepad` rather than IOKit for controller input. It supports the
standard controller surface used by the existing semantic bindings:

- A, B, X, and Y
- D-pad directions
- Menu and View/Options buttons
- Left and right shoulder buttons
- Left and right stick clicks
- Left and right analog sticks
- Left and right analog triggers, including threshold-generated trigger keys

The backend discovers controllers at startup and by connect/disconnect
notifications, polls each device once per tic, and uses the existing joystick
menu, configuration persistence, dead-zone, sensitivity, response-curve, and
binding systems. Disabling a device, disabling global joystick input, and
disconnecting a controller all release cached button state and clear analog
state.

It intentionally does not add haptics, controller-brand-specific handling,
Start/Back/Guide support, motion/touch controls, or generic HID joystick
support. It only accepts controllers macOS exposes through
`GCExtendedGamepad`.

## Changed files

| File | Why it changed |
| --- | --- |
| `CMakeLists.txt` | Defines the Apple-only, default-off `OSX_GAMECONTROLLER_BACKEND` option; rejects it unless `OSX_COCOA_BACKEND=ON`; selects a 26.0 deployment target when enabled and preserves 10.13 otherwise. |
| `src/CMakeLists.txt` | Compiles exactly one Cocoa controller implementation and links exactly its owner framework: legacy `i_joystick.cpp`/IOKit by default, or `i_gamecontroller.mm`/GameController when selected. |
| `src/common/platform/posix/cocoa/i_gamecontroller.mm` | Implements the isolated GameController manager and `IJoystickConfig` devices, semantic key events, axes, persistence, hot-plug, and neutralization behavior. |
| `src/posix/osx/zdoom-info.plist` | Substitutes the selected deployment target into `LSMinimumSystemVersion` and declares controller interaction with the ExtendedGamepad profile. |

## Build

Use a separate out-of-tree build directory. `/private/tmp` keeps generated
objects, bundles, and PK3 files out of the checkout; use another location if
you want to keep builds between cleanup/reboots.

### Debug GameController build

```sh
cmake -S . -B /private/tmp/uzdoom-gamecontroller-debug \
  -DCMAKE_BUILD_TYPE=Debug \
  -DOSX_COCOA_BACKEND=ON \
  -DOSX_GAMECONTROLLER_BACKEND=ON

cmake --build /private/tmp/uzdoom-gamecontroller-debug --target zdoom -j 4
```

The resulting application is:

```text
/private/tmp/uzdoom-gamecontroller-debug/uzdoom.app
```

### Release GameController build

```sh
cmake -S . -B /private/tmp/uzdoom-gamecontroller-release \
  -DCMAKE_BUILD_TYPE=Release \
  -DOSX_COCOA_BACKEND=ON \
  -DOSX_GAMECONTROLLER_BACKEND=ON

cmake --build /private/tmp/uzdoom-gamecontroller-release --target zdoom -j 4
```

The project declares its base version in `src/version.h`. Each build records its
exact Git-derived version in `BUILD_DIR/gitinfo.h`; use that generated value when
copying a custom build so rebased builds install side by side:

```sh
BUILD_DIR=/private/tmp/uzdoom-gamecontroller-release
BUILD_VERSION="$(awk -F'"' '/GIT_DESCRIPTION/ { print $2; exit }' "$BUILD_DIR/gitinfo.h")"
INSTALL_DIR="$HOME/Applications/Doom/ports/uzdoom-${BUILD_VERSION}"

mkdir -p "$INSTALL_DIR"
cp -R "$BUILD_DIR/uzdoom.app" "$INSTALL_DIR/"
```

This produces `~/Applications/Doom/ports/uzdoom-<Git-description>-custom/`
containing `uzdoom.app`. Re-running the copy command updates the bundle in that
same versioned directory.

For fast local iteration, add `-DFORCE_NO_LTO=ON` to either configure command.
That disables the project's Release/RelWithDebInfo LTO selection; it was used
for the initial backend verification and is not required for normal builds.

### Default IOKit regression build

Keep this configuration available when rebasing so the opt-in behavior remains
isolated:

```sh
cmake -S . -B /private/tmp/uzdoom-cocoa-default \
  -DCMAKE_BUILD_TYPE=Debug \
  -DOSX_COCOA_BACKEND=ON \
  -DOSX_GAMECONTROLLER_BACKEND=OFF

cmake --build /private/tmp/uzdoom-cocoa-default --target zdoom -j 4
```

The GameController option must fail when Cocoa is disabled:

```sh
cmake -S . -B /private/tmp/uzdoom-invalid \
  -DOSX_COCOA_BACKEND=OFF \
  -DOSX_GAMECONTROLLER_BACKEND=ON
```

Expected error:

```text
OSX_GAMECONTROLLER_BACKEND requires OSX_COCOA_BACKEND=ON
```

## Git backup and upstream updates

This checkout uses two remotes:

| Remote | Repository | Purpose |
| --- | --- | --- |
| `origin` | `git@github.com:jmacs/UZDoom.git` | Personal fork and backup for `macos_gamepad`. |
| `upstream` | `git@github.com:UZDoom/UZDoom.git` | Official UZDoom source used for updates. |

`origin/trunk` is a clean mirror of `upstream/trunk`; do not make independent
commits on it. `macos_gamepad` tracks `origin/macos_gamepad`. It is a private
maintenance branch, not intended for a pull request. Before starting an
update, ensure the worktree is clean and use this sequence:

```sh
git fetch upstream --prune
git push origin upstream/trunk:trunk
git fetch origin

git switch macos_gamepad
git rebase origin/trunk
```

The first command updates the local `upstream/trunk` reference from the
official repository. The second advances the fork's `trunk` to that exact
commit; it is not a merge or a rebase. The third refreshes the local
`origin/trunk` reference after the push. The rebase is the only step expected
to require conflict resolution: it replays the gamepad commits onto the newly
mirrored fork trunk.

If the `git push origin upstream/trunk:trunk` command is rejected, stop and
inspect the unexpected commits on `origin/trunk`; it should normally be a
fast-forward-only mirror. For a particular official release, substitute the
desired upstream tag or branch for `upstream/trunk` in the push command, then
rebase as usual onto the resulting `origin/trunk`. After resolving rebase
conflicts and running the build and hardware checks below, update the backup
branch. Rebasing rewrites commit IDs, so this push is expected:

```sh
git push --force-with-lease origin macos_gamepad
```

Use `--force-with-lease`, rather than `--force`, so Git refuses to overwrite a
remote change that is not present locally. A normal backup push when no rebase
occurred is simply:

```sh
git push
```

## Rebase checklist

When rebasing this branch onto trunk, resolve changes conservatively:

1. Keep `OSX_GAMECONTROLLER_BACKEND` defaulting to `OFF` and retain its Cocoa
   dependency check.
2. Keep the legacy and GameController controller translation units mutually
   exclusive. Do not link IOKit in a GameController build or compile both
   implementations together, because they provide the same free functions.
3. Preserve macOS deployment targets: `10.13` for the default Cocoa/IOKit build
   and `26.0` for the selected GameController build. `LSMinimumSystemVersion`
   must remain tied to the same target.
4. Keep the plist's `GCSupportedGameControllers` value as an array containing a
   dictionary with `ProfileName` set to `ExtendedGamepad`.
5. Keep `i_gamecontroller.mm` self-contained. Shared Cocoa input, menus, and
   shared controller abstractions should not need changes for this workaround.
6. Rebuild both configurations above. Confirm the default executable links
   IOKit and the selected executable links GameController:

   ```sh
   otool -L BUILD_DIR/uzdoom.app/Contents/MacOS/uzdoom | rg 'IOKit|GameController'
   ```

7. Validate each generated plist and minimum version:

   ```sh
   plutil -lint BUILD_DIR/uzdoom.app/Contents/Info.plist
   /usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' \
     BUILD_DIR/uzdoom.app/Contents/Info.plist
   ```

8. With a real controller, test startup detection, hot-plug, Menu and
   View/Options buttons, the other digital controls, sticks, triggers,
   configuration persistence, and releases after disabling the device, setting
   `use_joystick` to false, and disconnecting while a control is held.

## Initial verification

This branch was verified with both Cocoa build selections. The default build
compiled `i_joystick.cpp`, linked IOKit, and generated a `10.13` bundle minimum.
The selected build compiled `i_gamecontroller.mm`, linked GameController, and
generated a `26.0` bundle minimum. The invalid option combination failed as
expected. Hardware testing passed with a connected controller.
