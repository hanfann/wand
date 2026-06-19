# React Native / Expo showcase

A small Expo app exercised by Wand. Like the native showcase, it mirrors the
last recognized gesture into a `#status` element, so every complex gesture is
verified through the accessibility tree alone.

The interesting widgets (`testID`s): `status`, `tapButton`, `longPressBox`,
`pinchBox`, `rotateBox`, `dragHandle`, `zoneA`, `zoneB`, `textInput`.

## Run

```bash
npx expo run:ios --device "<booted-udid>"   # builds, installs, starts Metro
```

Then drive it:

```bash
wand ui
wand tap "#tapButton"
wand pinch "#pinchBox" 2.0
wand dragdrop "#dragHandle" "#zoneB"
./e2e.sh                                    # full gesture regression suite
```

## React Native accessibility note (important)

A `testID` only appears in the **native iOS accessibility tree** (as the
`AXUniqueId` Wand matches on) when the view is an accessibility element.
`Pressable`/`TextInput` are accessible by default, but plain `View`s are not —
so the gesture `View`s here set **`accessible={true}`** alongside `testID`.
Without it, the `testID` is dropped from the tree (only child `Text` labels show).
This is the single most common reason a React Native element is "invisible" to
UI automation. Put `testID` (and `accessible` for plain views) on the leaf
interactive element, not a deep wrapper.
