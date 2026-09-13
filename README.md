# Godot NPC Village

![Ashmoor market square](docs/conversation.png)

A small medieval village in Godot 4.8 where the villagers hold conversations with each
other that nobody wrote. The Claude API writes their dialogue while the game runs, and
ElevenLabs speaks it aloud in a different voice for each villager.

The village is Ashmoor: a market square with a fountain, a smithy, a bakery, a tavern
called the Crooked Hart, a chapel, a watermill and a windmill. Six villagers stand in
three groups around it. The lord's tax collector is expected before the harvest, and the
miller's youngest daughter has not been seen for six days. None of the villagers have
scripted lines about any of that. They have personalities, opinions about each other, and
things they each know and are not saying, and they work the rest out between them every
time you walk up.

## What actually happens when you walk into the square

1. An `Area3D` around the group notices the player and tells the `ConversationGroup`.
2. The group asks `ConversationDirector` for a *beat*: three to six turns of dialogue.
3. The director sends one request to the Claude API carrying the village's situation and
   the full personality of everyone standing there, and gets the whole beat back as
   schema-validated JSON.
4. Each turn goes to an `NPC`, which asks `VoiceService` for the audio, plays it from an
   `AudioStreamPlayer3D`, and shows the line on the subtitle HUD.
5. Two turns before the beat runs out, the group quietly requests the next one, so the
   conversation continues without a pause.

Walk away and the conversation trails off. Walk back and they are talking about something
else, because the situation they were given has changed.

![The village from above](docs/aerial.png)

## Running it

The project needs two API keys. Both are read from `.env` in any parent directory of the
project, from the process environment, or from `user://secrets.cfg`. Nothing is committed
and nothing is written back.

```
ANTHROPIC_API_KEY=sk-ant-...
ELEVEN_LABS_API_KEY=sk_...
```

Then pull the addons, which are not committed here, and open the project.

```
python tools/pull_addons.py
```

The game runs without either key. With no Anthropic key the villagers fall back to the
authored lines on each group; with no ElevenLabs key they mime and you read the subtitles.
Any line already in the voice cache still plays either way.

## Cost, and why the village is quiet until you arrive

Both services are metered, and this was the single most important thing to get right.

A beat costs roughly one cent of Claude tokens and about 330 characters of ElevenLabs
quota. A free ElevenLabs account allows 10,000 characters a month in total, which is about
thirty conversations. During development, three groups left chattering to an empty square
spent 12.6% of the month's voice quota in one idle run that nobody was present to hear.

So `ConversationGroup.converse_only_when_player_present` defaults to on. The village is
silent until you walk into it, and the entire budget goes on conversations that actually
reach the player. `VoiceService.session_character_ceiling` is a second guard, defaulting to
900 characters per session, and the service reads the account's real remaining quota at
startup and lowers itself to fit.

Three things keep the cost down beyond that:

- **The voice cache.** Every clip is keyed by the hash of the text, the voice and the
  synthesis settings, and kept under `user://voice_cache/`. A line that has been said
  before costs nothing and needs no key, no quota and no network.
- **Prompt caching.** The village lore, the direction and the personas are one stable
  prefix with the cache breakpoint on the last block, so a second request for the same
  group reads 1,453 tokens from cache instead of being billed for them. Measured on this
  project: `cache_read_input_tokens` 1453, `input_tokens` 70.
- **Low effort.** Village small talk does not need deep reasoning, and `output_config.effort`
  of `low` is what keeps a beat inside the six or seven seconds that prefetching can hide.

### ElevenLabs free tier

Two limits are worth knowing before wondering why a villager is silent. Free accounts
cannot use *library* voices through the API and get HTTP 402 `paid_plan_required`; only the
21 *premade* voices work. Every villager in this project is therefore cast from premade
voices, and `test_npc_persona.gd` fails the build if anyone is given a blocked one.

## Tests

The suite is 57 tests and runs entirely from recorded fixtures. It never makes a network
request, so it costs nothing and works in CI with no credentials. This is enforced rather
than assumed: `RuntimeMode.is_offline()` detects GUT's runner on the command line and both
paid services refuse to send anything when it returns true.

Verified by running the full suite three times and checking the ElevenLabs quota before and
after: 2436 characters both times.

```
& 'C:\Godot\godot.exe' --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://tests/unit,res://tests/integration -gexit
```

On the Mac:

```
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://tests/unit,res://tests/integration -gexit
```

The fixtures in `tests/fixtures/` are real recordings, not hand-written approximations: a
genuine Claude response, a genuine ElevenLabs clip, and a sample `.env` with the CRLF line
endings the shared file really has.

## Layout

```
scripts/
  conversation/
    conversation_director.gd   Claude API client, autoloaded as ConversationDirector
    conversation_group.gd      Runs one conversation, owns the transcript and pacing
    conversation_turn.gd       One villager saying one thing
    npc_persona.gd             Who a villager is, and how they sound
  npc/
    npc.gd                     A villager: performs a turn, reports when it is done
    speaking_modifier.gd       SkeletonModifier3D that poses the body while speaking
  services/
    secrets.gd                 Key resolution, autoloaded as Secrets
    voice_service.gd           ElevenLabs client and clip cache, autoloaded as VoiceService
    runtime_mode.gd            Decides whether this process may use the network
  ui/
    subtitle_hud.gd            Screen-space subtitles
tools/
  build_personas.gd            Generates resources/personas/*.tres
  build_world.gd               Generates scenes/npc.tscn and scenes/world.tscn
  pull_addons.py               Vendors the addons listed in tools/addons.json
```

The scenes in `scenes/` are committed and are what the game loads; nothing is assembled at
run time. They are generated rather than placed by hand because the village is six hundred
modular pieces, and a script makes the layout reproducible. Signal connections are written
into the scene files with `CONNECT_PERSIST` so the wiring lives in the scene rather than in
a `_ready` that rebuilds it every run.

## Design notes

**Beats, not lines.** Asking the model for one line at a time would put a round trip
between every villager speaking. A beat of three to six turns costs one round trip, and
requesting the next beat two turns early hides it entirely.

**Cutting a beat is deliberate.** A beat is a guess about a moment. Once the player arrives
or leaves, the rest of that guess is wrong, so the group drops it and asks again with the
new situation.

**The speaking motion is procedural.** There is no talking animation in the vendored set,
but that is not the only reason. A canned talking loop mimes for a fixed length against
lines whose length nobody knows in advance. `SpeakingModifier` poses the head and chest
against the clip that is actually playing, so a villager moves for exactly as long as they
are speaking, whatever the model invented. Gestures (nod, shrug, lean in, turn away) are
posed the same way and blend out of whatever the body was already doing.

It has to be a `SkeletonModifier3D`. The skeleton applies its animation every frame, and
anything writing bone poses before that is simply overwritten.

**Subtitles are screen-space.** They were first tried as a `Label3D` over each villager's
head, which cannot work: a world-space label is sized in metres, so it is unreadable across
the square and fills the screen up close. The name plate stays in world space, because that
genuinely should shrink with distance.

## Known gaps

- The villagers are recoloured Quaternius mannequins rather than clothed medieval
  characters. Quaternius's Medieval Village MegaKit and fantasy character outfits are CC0
  and would be a straight upgrade, but itch.io gates downloads behind a click-through that
  cannot be scripted. Drop them into `assets/quaternius/` and repoint `build_world.gd`.
- There are no conversational animations in the vendored Mixamo set (no talking, nodding or
  shrugging clips), which is why gestures are procedural. Mixamo has free ones behind an
  Adobe login.
- The API keys live in the client. That is fine for a local project and wrong for anything
  shipped, where the requests should go through a relay that holds the keys server-side.

## Third-party assets

All assets are CC0 or MIT and are attributed below.

| Asset | Source | License |
| --- | --- | --- |
| Fantasy Town Kit 2.0 | <https://kenney.nl/assets/fantasy-town-kit> | CC0 1.0 |
| Graveyard Kit 5.0 | <https://kenney.nl/assets/graveyard-kit> | CC0 1.0 |
| Mini Forest 1.0 | <https://kenney.nl/assets/mini-forest> | CC0 1.0 |
| Nature Kit | <https://kenney.nl/assets/nature-kit> | CC0 1.0 |
| Mannequin characters | <https://quaternius.com> | CC0 1.0 |
| Mixamo idle animation | <https://www.mixamo.com> | Mixamo license, via the player controller addon |

The Kenney kits are in `assets/kenney/`, each with the `License.txt` from its download. The
mannequins and the idle animation come from the `3d_player_controller` addon.

## Addons

The addons are not committed. `python tools/pull_addons.py` vendors them from their own
repositories, as listed in `tools/addons.json`:

- [3d_player_controller](https://github.com/kirbycope/godot-3d-player-controller-addon)
- [controls](https://github.com/kirbycope/godot-controls)
- [weather_fx](https://github.com/kirbycope/weather-fx)
- [date_and_time](https://github.com/kirbycope/date-and-time)

GUT is vendored the same way, pinned to `v9.6.1` in the manifest so the test framework
cannot drift under the suite. It is third-party and never edited here, so it is never
pushed back.

If any of these are edited, run `python tools/push_addons.py -m "..."` before pushing this
project, or the addon half of the work stays on the machine it was made on.
