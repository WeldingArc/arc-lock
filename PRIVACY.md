# Arc Lock — Privacy Policy

_Last updated: October 28, 2026_

**Arc Lock collects no data.** It has no account, no server, no analytics, no ads and no tracking. Nothing you do in Arc Lock leaves your iPhone.

## What Arc Lock stores, and where

Everything stays on your iPhone, in Arc Lock's own storage (an App Group shared only with Arc Lock's own extensions):

- the blocks you create: their names, hours, days, daily limits, time-outs and the website addresses you type;
- Apple's **opaque tokens** for the apps, categories and websites you pick. Arc Lock can't read which apps these tokens stand for — only iOS can show their names and icons;
- for each daily limit, how far today's use has gone, in tenths (for example "over half used"), and for each time-out, when its current break ends. iOS tells Arc Lock when a threshold passes; it never tells Arc Lock how long you used which app;
- for each place block (from version 1.2): the place you chose on the map (its coordinates, the size of the circle and the name you gave it), whether you're inside it as iOS last reported, and when the current block started and ends. Arc Lock keeps no record of where you go.

Deleting Arc Lock deletes all of it.

## Screen Time

Arc Lock uses Apple's Screen Time frameworks (Family Controls, Managed Settings, Device Activity) with the permission you grant. Apple keeps your activity data on the device and does not share it with Arc Lock. The minutes shown under a daily limit or time-out are drawn by a Device Activity report extension: iOS gives the numbers only to that sandboxed extension, which can't send them anywhere, and the Arc Lock app never receives them. Arc Lock never sends Screen Time information anywhere.

## Location (place blocks only)

Arc Lock asks for your location only when you set up a place block, and you can say no — every other feature works without it. With your permission, iOS watches the edge of each place you chose and tells Arc Lock when you cross it, so a block can start when you arrive and end when you leave, even while Arc Lock is closed ("Always" access). Arc Lock uses your current location only on your iPhone, to start or end those blocks and to center the map; it never stores your location history and never sends your location anywhere. You can turn location access off any time in Settings › Arc Lock › Location.

Showing the map and searching for a place use Apple Maps: the map area on screen (which may be around where you are) and what you type go to Apple to show the map and find the place, under Apple's privacy policy. Arc Lock itself never sends your location anywhere and doesn't keep your searches.

## Notifications

If you allow notifications, Arc Lock shows local reminders (for example "5 minutes left for today"). They are created on your iPhone; no notification server is involved.

## Links

The About section links to this repository on GitHub. Opening a link takes you to GitHub in your browser, where GitHub's own privacy policy applies.

## Children

Arc Lock is a self-control tool for the person who owns the iPhone. It does not collect any information from anyone, including children.

## Changes and contact

If this policy ever changes, the new version will be published here with a new date. Questions: open an issue at <https://github.com/WeldingArc/arc-lock/issues>.
