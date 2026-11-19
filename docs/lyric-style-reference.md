# Lyric style reference

> Internal prototyping notes. They describe third-party apps that were studied while building the
> first version. Not shipped with the app; keep this file private.

Catalogue of looks seen in reference videos. Fill one entry per distinct treatment, then implement it
(see CLAUDE.md, "Lyric styles from reference videos").

## Entry template
- **Source / time**: video name, sheet number, frame
- **Layout**: how words are arranged (stack, cascade, diagonal, centred block, one giant word...)
- **Type**: size contrast, weights, fonts (sans / serif / script), italics, caps
- **Colour**: text colours, backgrounds, highlight boxes
- **Extras**: icons or emoji next to nouns, underlines, scribbles, shapes
- **Enter / exit**: pop, slide, rotate, typewriter, wipe... direction and speed
- **Idle motion**: wobble, bounce, beat reaction
- **Timing**: when each word appears relative to being sung
- **Status**: not started / implemented as `<template or look name>`

## 1. "on my shirt" cascade (from the user's screenshot)
- **Source / time**: lyric video frame, words "on / my / shirt" (a handwritten "name" above)
- **Layout**: vertical cascade, one word per row, rows staggered left / centre / right; sizes very uneven ("my" huge, "on" small, "shirt" medium)
- **Type**: bold grotesque sans for most words; one word in a handwritten script (signature-like); "shirt" in italic
- **Colour**: warm orange and coral-red words on near-black; "shirt" in white on a coral box; "my" on a dark translucent box
- **Extras**: a flat red t-shirt icon next to the word "shirt" (noun -> icon)
- **Enter / exit**: words appear as they are sung, each snapping in with a small pop
- **Idle motion**: unknown from one frame
- **Timing**: one word at a time on the beat
- **Status**: the old template-based Kinetic style was replaced by Ship (entry 5); the icon idea lives on in `iconMap`

## 2. Constellation (user screenshot: "wasted / bridges / burned / i've / down")
- **Layout**: words are small four-point stars scattered across a black sky, labels beneath; thin lines join consecutive words
- **Colour**: salmon/pink-red on black; current word is large and white with a red glowing ring marker
- **Enter**: star appears and the line to it draws itself as the word is sung; sung words stay as dim labels
- **Status**: implemented as style `Constellation`

## 3. Verci style menu: Ship, Fisheye, Visual, Fisheye Visual, Codestyle, Codestyle Visual, Branches, Web, Constellation
- All implemented, in that order, in the menu bar menu (`LyricsMenu`).
- Font list: SF Pro, SF Rounded, New York, Helvetica Neue, Avenir Next, Futura, Didot.

## 5. Ship (verci-hero.mp4, 12 fps zoom 3.6-4.9 s)
- **Layout**: one word per row, centred with small random sideways offsets; 1-3 rows plus one leaving.
- **Type**: SF Pro semibold; about 1 in 4 words italic. Middle row about 1.7x the bottom row, top row about half.
- **Colour**: newest word white on a hot-pink box; when the next word arrives it moves to the middle, the box turns
  dark maroon with coral text, then (often) the box fades and the word is plain red. Top row plain red.
- **Extras**: pink SF Symbols beside nouns/verbs (bubble for "telling", dice for "chances", wind for "blew",
  car, phone, person, heart, signature...), a few emoji (pointing hand). Boxes are uneven, like tape; words tilt in 3D.
- **Enter / exit**: new word pops in quickly at the bottom; all rows slide up over ~0.3 s; the top word shrinks and
  fades upward. A new line clears the stack (old one fades in ~0.2 s).
- **Status**: implemented as `StreamStage` (the Stream style).

## 6. Visual (screen recording 14-08-36, 8-14 s)
- Album art turned into a one-colour picture (bright parts in the accent colour, dark parts see-through), centred,
  with the lyric words smaller under / over its lower part. Status: `ArtVisual` + `StreamStage(compact:)`.

## 7. Lock screen (screen recording 14-09-28)
- Date and big time at the top, Ship lyrics below, red edge glow tracing the notch.
  Status: `LockClock` (real lock screen not possible without private APIs).

## 4. Lumn lyric list (lumn-demo.mp4 at 17 s): card with art + controls left, lines right; current line bold white
filling in word by word, others smaller, blurred and dimmer with distance.
- **Status**: implemented as `LyricsCard` / `CardLyricList` in the player window.
