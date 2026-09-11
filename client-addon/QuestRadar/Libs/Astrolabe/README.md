# Astrolabe (vendored)

Positions icons on the minimap: converts a normalised map coordinate into a
minimap offset, handling zoom, rotation, minimap shape and edge clamping.

## Origin

Copied from [Trimitor/WDM-addons](https://github.com/Trimitor/WDM-addons)
(`!Astrolabe`) — the fork that actually targets a genuine 3.3.5.12340 client.
Original author Esamynn; this fork by Esamynn and Trimitor.

- Library identity: `Astrolabe-0.4`, revision **107**
- The upstream `Astrolabe-1.0` is **not usable here**: it targets Mists of
  Pandaria (`## Interface: 50001`) and calls `GetAreaMaps()` from inside
  `activate()`, which runs at load. That function does not exist on 3.3.5a, so
  the library dies immediately — silently, since `scriptErrors` defaults to `0`
  on this client. It also registers under a different major name, so it would
  not even supersede this one.

## Why vendored rather than a dependency

So the addon works from a single download. DongleStub deduplicates by major
name and keeps the highest minor, so a player who also runs the standalone
`!Astrolabe` addon ends up with exactly one instance in memory, whichever is
newer — no conflict, no duplication. That is what DongleStub is for.

`## OptionalDeps: !Astrolabe` is kept in the `.toc`: harmless when absent, and
it gives the standalone copy a favourable load order when present.

## Licence

LGPL — see `lgpl.txt`, kept alongside the sources as the licence requires.

## Updating

Replace the four Lua/XML files wholesale from the fork above, keep `lgpl.txt`,
and re-check the revision number recorded here. Do not swap in an
`Astrolabe-1.0` release.
