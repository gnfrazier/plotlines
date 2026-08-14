# OSM Tag Reference

Working reference of OpenStreetMap tags relevant to the rebrand, in two parts: "cool/interesting things to see" (content/curation, Leg 6, FR5, FR23) and cycling-specific infrastructure (routing input, cyclist support amenities, greenways). Source: [OSM Map Features](https://wiki.openstreetmap.org/wiki/Map_features), cross-checked against `Key:tourism`, `Key:historic`, `Key:leisure`, `Key:natural`, `Key:man_made`, `Key:amenity`, `Key:cycleway`, `Key:highway`, and the `Bicycle` wiki page.

# "Cool / Interesting Things to See"

Scoped to what a touring cyclist might detour or stop for — not general infrastructure tagging.

**Status column:**
- **Implemented** — already wired into `ctp_core` (see `providers.py`)
- **Candidate** — fits the theme, not yet wired up
- **Candidate (caution)** — fits, but likely to over-trigger or need a filter before it's usable
- **Excluded** — considered and dropped; functional/institutional, not a sight

## Currently implemented

| Tag | Description | Where |
|---|---|---|
| `historic=*` (wildcard, any value) | Any historic-tagged feature | FR5, `providers.py` `TAGS = {"historic": True}` |
| `tourism=artwork` | Sculpture, mural, or other permanent public art | FR5 |
| `tourism=hotel`/`motel`/`guest_house`/`camp_site` | Lodging | FR14 — not a "sight," listed for completeness |

`historic=*` is a flat wildcard today — a `monument` and a `boundary_stone` score identically. The full value list below is a candidate for sub-weighting later (e.g. weight `castle`/`fort`/`archaeological_site` higher than `boundary_marker`).

## Historic — all documented values (already covered by the wildcard)

| Tag | Description |
|---|---|
| `historic=castle` | Castle |
| `historic=fort` | Fortification |
| `historic=citywalls` / `castle_walls` | City or castle defensive walls |
| `historic=battlefield` | Historic battlefield |
| `historic=earthworks` | Defensive earthworks |
| `historic=moat` | Moat |
| `historic=archaeological_site` | Generic archaeological site |
| `historic=ruins` | Ruins |
| `historic=building` | Generic historic building |
| `historic=house` | Historic residence |
| `historic=manor` | Historic manor house |
| `historic=monument` | Large commemorative structure |
| `historic=memorial` | Smaller commemorative feature |
| `historic=statue` | Statue |
| `historic=wayside_cross` | Wayside cross |
| `historic=wayside_shrine` | Wayside shrine |
| `historic=church` | Historic church |
| `historic=tumulus` | Burial mound |
| `historic=stone_circle` | Prehistoric stone circle |
| `historic=menhir` / `standing_stone` | Standing megalith |
| `historic=mine` / `mine_shaft` / `mine_adit` | Historic mining site/shaft/entrance |
| `historic=quarry` | Historic quarry |
| `historic=wreck` / `ship` | Historic shipwreck / preserved ship |
| `historic=roman_road` | Roman road |
| `historic=railway_station` | Historic railway station |
| `historic=bridge` | Historic bridge |
| `historic=milestone` | Milestone marker |
| `historic=wall` | Historic wall |
| `historic=well` | Historic well |
| `historic=boundary_stone` / `boundary_marker` | Boundary marker |
| `historic=folly` | Ornamental folly |

## Tourism — beyond `artwork`

| Tag | Description | Status |
|---|---|---|
| `tourism=museum` | Scientific, historical, artistic, or cultural exhibits | Candidate |
| `tourism=gallery` | Building/room displaying visual art | Candidate |
| `tourism=viewpoint` | Scenic overlook | Candidate — strong fit, especially for climbing-theme routes |
| `tourism=zoo` | Zoological park | Candidate |
| `tourism=aquarium` | Aquatic animal exhibits | Candidate |
| `tourism=attraction` | Generic place of natural/historical interest | Candidate — catch-all, likely noisy without a name-tag filter |
| `tourism=theme_park` | Amusement park | Candidate (caution) — doesn't match the brand's "quiet touring" sentiment, evaluate before including |
| `tourism=information` | Info center, guidepost, or map | Excluded — supporting infrastructure, not a sight itself |
| `tourism=picnic_site` | Outdoor eating area | Excluded — functional |
| `tourism=apartment`/`chalet`/`hostel`/`alpine_hut`/`wilderness_hut`/`caravan_site`/`camp_pitch`/`trail_riding_station` | Various lodging | Excluded — lodging, not sights (FR14's domain) |
| `tourism=yes` | Generic tourist-interest flag | Excluded — no semantic content |

## Amenity — sightseeing/culture subset

| Tag                                                                                                                                                                 | Description                             | Status                                                                                                                      |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `amenity=place_of_worship`                                                                                                                                          | Church, temple, mosque, synagogue, etc. | Candidate — strong fit, common architectural landmark (not in the source fetch, added manually — standard, widely-used tag) |
| `amenity=arts_centre`                                                                                                                                               | Multi-discipline arts venue             | Candidate                                                                                                                   |
| `amenity=theatre`                                                                                                                                                   | Live performance venue                  | Candidate                                                                                                                   |
| `amenity=music_venue`                                                                                                                                               | Live music venue                        | Candidate                                                                                                                   |
| `amenity=planetarium`                                                                                                                                               | Planetarium                             | Candidate                                                                                                                   |
| `amenity=fountain`                                                                                                                                                  | Decorative/cultural fountain            | Candidate                                                                                                                   |
| `amenity=library`                                                                                                                                                   | Public library                          | Candidate — often notable architecture (esp. older Carnegie-era buildings)                                                  |
| `amenity=public_bookcase`                                                                                                                                           | Street-side book exchange               | Candidate — small but on-brand "quirky, curated" find                                                                       |
| `amenity=grave_yard`                                                                                                                                                | Small burial ground, often churchside   | Candidate — can be genuinely scenic/historic                                                                                |
| `amenity=cinema`                                                                                                                                                    | Movie theater                           | Candidate (caution) — usually modern/generic, weak fit                                                                      |
| `amenity=community_centre`/`conference_centre`/`events_venue`/`exhibition_centre`/`social_centre`/`stage`/`music_school`/`research_institute`/`school`/`university` | Institutional/functional venues         | Excluded — not sightseeing destinations                                                                                     |

## Leisure — sightseeing subset

| Tag | Description | Status |
|---|---|---|
| `leisure=nature_reserve` | Protected wildlife/flora/geological area | Candidate — strong fit, pairs well with lowest-traffic theme |
| `leisure=garden` | Decorative, structured plantings | Candidate |
| `leisure=park` | Open green recreational area | Candidate (caution) — extremely common tag, will over-trigger without a size/name filter |
| `leisure=bird_hide` / `wildlife_hide` | Wildlife observation structure | Candidate — niche but strongly on-theme |
| `leisure=marina` | Yacht/boat mooring | Candidate (caution) — mostly functional, occasionally scenic |
| everything else (`golf_course`, `stadium`, `pitch`, `playground`, `swimming_pool`, `fitness_centre`, `dog_park`, `bowling_alley`, `water_park`, `sauna`, etc.) | Recreational/sports facilities | Excluded — functional, not sights |

## Natural — sightseeing subset

| Tag | Description | Status |
|---|---|---|
| `natural=peak` | Hill/mountain summit | Candidate — strong fit for climbing theme |
| `natural=cliff` | Vertical rock drop | Candidate |
| `natural=arch` | Natural rock arch | Candidate — rare, notable |
| `natural=cave_entrance` | Cave entrance | Candidate |
| `natural=sinkhole` | Karst depression | Candidate |
| `natural=volcano` | Volcano | Candidate — rare in NC/WI, possible in Southern CA |
| `natural=hot_spring` / `geyser` | Geothermal features | Candidate — rare, notable where present |
| `natural=spring` | Natural groundwater spring | Candidate |
| `natural=bay` / `beach` / `blowhole` | Coastal features | Candidate — relevant mainly to Southern CA region |
| `natural=glacier` | Glacier | Candidate — not relevant to current regions (NC/WI/SoCal), keep for future region expansion |
| `natural=tree` | Single tree | Candidate (caution) — most instances are ordinary street trees; needs a notability filter (e.g. `denotation=natural_monument`) before use, not the raw tag |
| `natural=wood` | Forest/tree-covered area | Excluded — too generic to be "a sight" |

## Man Made — sightseeing subset

| Tag | Description | Status |
|---|---|---|
| `man_made=lighthouse` | Navigational light tower | Candidate — strong fit, coastal (SoCal) |
| `man_made=windmill` | Wind-powered mill | Candidate — strong fit, rural/historic charm |
| `man_made=watermill` | Water-powered mill | Candidate |
| `man_made=obelisk` | Tapered monument | Candidate |
| `man_made=torii` / `stupa` | Shinto/Buddhist gate or dome | Candidate — rare in current regions, keep for future expansion |
| `man_made=water_tower` | Elevated water tank | Candidate (caution) — common small-town landmark, may over-trigger |
| `man_made=silo` | Grain/bulk storage | Candidate (caution) — very common in rural NC; matches "grounded" sentiment but needs a filter to avoid noise |
| `man_made=pier` | Pier | Candidate (caution) — mostly functional, occasionally scenic (coastal) |
| `man_made=tower` | Generic free-standing tower | Candidate (caution) — too ambiguous alone, needs a sub-type or name check |
| `man_made=storage_tank`/`gasometer`/`works`/`kiln`/`mineshaft`/`crane`/`antenna`/`communications_tower`/`chimney`/`breakwater`/`beacon` | Industrial/utility structures | Excluded — functional, not sights |

---

# Cycling Infrastructure — Nodes & Ways

A second, distinct category from the "sights" tables above: tags that describe cycling-specific infrastructure itself — the paths, lanes, and support amenities a touring cyclist rides on or stops at. These split into three different uses, not one:

- **Routing input** — way-level tags that should feed weighting (lowest-traffic, surface-type themes), not display as a POI
- **POI candidate** — node-level amenities worth surfacing to the rider, similar in kind to the sights list but functional/support rather than "interesting to see"
- **Routability constraint** — tags that affect whether a route can legally/physically use a way at all; correctness issue, not a content one

## Dedicated cycling ways (`highway=*`)

| Tag | Description | Status |
|---|---|---|
| `highway=cycleway` | Dedicated, separated cycleway | Routing input — the clearest lowest-traffic/lowest-stress signal available |
| `highway=path` + `bicycle=yes`/`designated` | Non-specific multi-use path (typical tagging for greenways/multi-use trails) | Routing input |
| `highway=track` + `bicycle=yes` | Agricultural/forestry track open to cyclists | Routing input (caution) — surface is often unpaved gravel/dirt, cross-check against FR12 surface scoring before weighting as "low stress" |
| `highway=footway` + `bicycle=yes` | Footpath with cycling permitted | Routing input |
| `highway=bridleway` + `bicycle=yes` | Horse path, cycling permitted where local rules allow | Routing input (caution) — bicycle access isn't default-on, must check the tag rather than assume |
| `highway=pedestrian` + `bicycle=yes` | Pedestrian street, cycling sometimes permitted | Routing input |
| `highway=living_street` | Traffic-calmed residential street, pedestrians have priority | Routing input — low-stress by nature even without an explicit `bicycle=` tag |
| `highway=cyclist_waiting_aid` | Resting rail at a signalized junction | POI candidate (minor) |

## Cycleway provision on a road (`cycleway=*` and `cycleway:left/right/both=*`)

Describes what cycling provision exists alongside a normal road — distinct from `highway=cycleway`, which is a separate way entirely.

| Tag | Description | Status |
|---|---|---|
| `cycleway=track` / `cycleway:left\|right\|both=track` | Physically separated cycle track alongside the road | Routing input — strong low-traffic signal |
| `cycleway=lane` / `cycleway:left\|right\|both=lane` | Painted on-road bike lane | Routing input — weaker signal than `track`, still relevant |
| `cycleway=shoulder` | Usable road shoulder, common on rural highways | Routing input — directly relevant to NC/rural touring roads |
| `cycleway=shared_lane` | Sharrow-marked shared lane | Routing input (weak signal) |
| `cycleway=share_busway` | Shared with public transport | Routing input (caution) — likely lower fit for a rural-touring app |
| `cycleway=no` | Explicitly surveyed as having no cycling provision | Routing input |
| `cycleway=separate` | The cycle track is mapped as its own separate way (avoid double-counting) | Data-hygiene flag, not a scoring input itself |
| `cycleway=asl` | Advanced stop line / bike box at a junction | Excluded — junction-level detail, not relevant at touring-route scale |
| `oneway:bicycle=no` | Cyclists may travel contraflow on a one-way street | Routability constraint |
| `segregated=yes`/`no` | Whether cyclists/pedestrians are physically separated on a shared path | Routing input — feeds a comfort/stress signal alongside `lowest-traffic` |

Deprecated, skip: `cycleway=opposite`, `opposite_lane`, `opposite_track`, `opposite_share_busway`, `shared` (superseded by `oneway:bicycle` and `segregated`).

## Bicycle access (`bicycle=*`)

| Tag | Description | Status |
|---|---|---|
| `bicycle=designated` | Officially designated for bicycle use | Routing input — strongest positive signal |
| `bicycle=yes` | Bicycles permitted | Routing input |
| `bicycle=permissive` | Allowed, but no legal right-of-way (can be revoked) | Routing input (caution) |
| `bicycle=destination` | Allowed only if the destination is within the restricted area | Routability constraint |
| `bicycle=use_sidepath` | Compulsory to use an adjacent cycle track instead of the road | Routability constraint |
| `bicycle=dismount` | Must walk the bike through this section | Routability constraint — matters for a "ridable route" guarantee |
| `bicycle=no` | Bicycles prohibited | Routability constraint — hard exclusion |

## Named cycling routes / networks

No single canonical "greenway" tag exists in OSM — greenways and rail-trails are represented as a combination of the way-level tags above (typically `highway=cycleway` or `highway=path`, `surface=paved`/`asphalt`, `segregated=*`) plus a `name=*` (e.g. "Virginia Creeper Trail"), and often grouped into a route relation. Worth confirming against the actual NC/Wisconsin/Southern CA extracts rather than assuming a specific pattern.

| Tag | Description | Status |
|---|---|---|
| `type=route` + `route=bicycle` | Route relation grouping a named cycling route's ways together | Candidate — lets the app surface "you're riding the X Greenway" as content, not just infer it from geometry |
| `network=lcn` | Local cycle network | Candidate |
| `network=rcn` | Regional cycle network | Candidate |
| `network=ncn` | National cycle network (e.g. East Coast Greenway) | Candidate — strong fit, these are exactly the named, curated routes the brand voice would want to call out |
| `disused:railway=rail` (co-tagged with a cycleway) | Marks a rail-trail's former-railway provenance | Candidate (minor) — flavor detail for content/narration, not routing |

## Cyclist support amenities (nodes)

| Tag | Description | Status |
|---|---|---|
| `amenity=bicycle_repair_station` | Roadside self-service tools (and often a pump) | POI candidate — strong fit, directly useful mid-ride |
| `amenity=bicycle_parking` | Bicycle parking | POI candidate |
| `amenity=bicycle_rental` | Bike-share / rental point | POI candidate |
| `amenity=bicycle_wash` | Bike wash station | POI candidate (minor) |
| `amenity=compressed_air` | Tire/tyre air pump | POI candidate |
| `amenity=charging_station` (bicycle-relevant subset) | E-bike charging | POI candidate — check for a `bicycle=yes` sub-tag, most charging_station instances are for cars |
| `vending=bicycle_tube` | Inner-tube vending machine | POI candidate (minor) |
| `shop=bicycle` | Bike shop (sales/service) | POI candidate — strong fit, meaningfully different from a roadside repair station |
| `amenity=drinking_water` | Potable water source | POI candidate — high practical value on longer/hot rides |
| `amenity=bench` / `amenity=shelter` | Seating / weather shelter | POI candidate (minor) |

## Mountain Biking (MTB) — subset of cycling

Distinct character from the road-touring tags above: dirt singletrack and trail-difficulty grading rather than road surface/traffic. The project's five existing themes (flattest, most climbing, lowest traffic, fewest turns, most art/history) are road-touring themes — MTB doesn't fit any of them without its own difficulty-aware weighting, so treat this as a genuinely separate mode to consider, not free extra content on top of the road themes.

| Tag                                                                 | Description                                                | Status                                                                                 |
| ------------------------------------------------------------------- | ---------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `route=mtb`                                                         | MTB-specific route relation, parallel to `route=bicycle`   | Candidate                                                                              |
| `highway=path`/`track` + `mtb=*` or `bicycle=yes`                   | Off-road singletrack/trail                                 | Routing input — a distinct trail graph from the road-cycling tags above                |
| `mtb:scale=0–6`                                                     | IMBA/European difficulty scale for descents/level trails   | Candidate — difficulty content; only a routing input if the app weights by rider skill |
| `mtb:scale:uphill=0–5`                                              | Difficulty grading for climbing sections                   | Candidate                                                                              |
| `mtb:scale:imba=0–4`                                                | North American difficulty scale for built/flow trails      | Candidate                                                                              |
| `mtb:type=crosscountry`/`allmountain`/`downhill`/`trial`/`freeride` | Trail style/intent classification                          | Candidate                                                                              |
| `mtb:description=*` / `mtb:name=*`                                  | Informal/rider-known trail info and naming                 | Candidate (minor)                                                                      |
| `aerialway:bicycle=yes`/`summer`/`no`                               | Chairlift bike-carry capability at a lift-served bike park | Excluded — not human-powered                                                           |

## Barriers (routability constraints)

| Tag | Description | Status |
|---|---|---|
| `barrier=cycle_barrier` | Chicane/bollard array forcing a slow-down or dismount | Routability constraint |
| `barrier=bollard` | Bollard(s) blocking motor traffic | Routability constraint — usually still bike-passable, verify |
| `barrier=gate` | Gate across a path | Routability constraint — access value on the gate itself matters (`access=`, `bicycle=`) |
| `kerb=no`/`flush` | No/flush kerb at a crossing | Minor routing-quality signal, not a hard constraint |

---

# Other Human-Powered Outdoor Activities

Broadened scope per the rebrand discussion: gathering what OSM has for other human-powered activities, even though none of these have a current FR, theme, or product commitment. Purely reference material at this point — inclusion here is not a decision to build any of it.

## Paddling (Canoe / Kayak)

No existing hook in the app at all — this is a different medium (water, not road/trail).

> **Measured, 2026-08-14 (SPIKE-04).** This table has now been checked against real tag
> density in the NC / Wisconsin / Southern CA regions —
> [`spikes/SPIKE-04/results/RESULTS.md`](../spikes/SPIKE-04/results/RESULTS.md) has the
> per-region counts. The short version: the **access** rows are real but thin, and the
> **difficulty** rows are effectively empty in North America.
> `whitewater:section_grade` has 2,338 uses worldwide, of which **2,046 are in Europe and
> 58 in all of North America** — and zero in any region tested, including Western NC.
> `canoe=*` and `portage=*` are the opposite: North America uses them *more* than Europe
> does (51,929 and 8,841 versus 31,093 and 1,708), so this is a continent that maps
> paddling **access** and does not map paddling **difficulty**. Treat every "Candidate"
> below as *schema exists, data may not*.

| Tag                                                                                     | Description                                                               | Status                                                                |
| --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| `canoe=put_in`                                                                          | Land/water transition point for launching                                 | Candidate — the paddling equivalent of a trailhead                    |
| `waterway=access_point`                                                                 | Generic canoe/kayak put-in or take-out location                           | Candidate                                                             |
| `whitewater=put_in` / `egress` / `put_in;egress`                                        | Put-in, take-out, or combined access point on a graded whitewater section | Candidate                                                             |
| `whitewater:put_in;egress=pier`/`rubble`/`sand_strand`/`steps`                          | Physical substrate at an access point                                     | Candidate (minor detail)                                              |
| `canoe=yes`/`designated`/`permissive`/`permit`/`customers`/`discouraged`/`private`/`no` | Paddling access/legality on a waterway                                    | Routability-equivalent constraint — paddling's version of `bicycle=*` |
| `canoe=portage` / `whitewater=portage_way`                                              | Overland carry route around an obstacle                                   | Routability constraint                                                |
| `whitewater:section_grade=0–6`                                                          | International Scale of River Difficulty for a section                     | Candidate — difficulty content, parallel to `mtb:scale`               |
| `whitewater:rapid_grade=0–6`                                                            | Difficulty of an individual rapid                                         | Candidate (minor)                                                     |
| `rapids=*`                                                                              | Presence/grade of rapids                                                  | Candidate                                                             |
| `waterway=waterfall`/`weir`/`lock_gate`/`hazard`                                        | Hard obstacles or hazards on a waterway                                   | Routability constraint                                                |
| `waterway=canoe_pass`                                                                   | Marked bypass channel around a barrier                                    | Routability constraint                                                |
| `shop=canoe_hire`                                                                       | Boat/gear rental                                                          | POI candidate                                                         |

## Cross-Country / Nordic Skiing

Also no existing hook. Seasonal and regional fit is the open question — plausible for the Wisconsin region, much less so for NC or Southern CA.

| Tag                                                                          | Description                                                             | Status                                                          |
| ---------------------------------------------------------------------------- | ----------------------------------------------------------------------- | --------------------------------------------------------------- |
| `piste:type=nordic`                                                          | Groomed cross-country ski trail                                         | Candidate                                                       |
| `piste:type=skitour`                                                         | Backcountry ski-touring route (human-powered climb + descent)           | Candidate — the most clearly "human-powered" of the piste types |
| `piste:type=hike`                                                            | Winter/nordic-walking route, distinct from the summer hiking tags below | Candidate (minor)                                               |
| `piste:difficulty=novice`/`easy`/`intermediate`/`advanced`/`expert`          | Nordic trail difficulty                                                 | Candidate                                                       |
| `piste:grooming=classic`/`skating`/`classic;skating`/`scooter`/`backcountry` | Grooming style/condition                                                | Candidate                                                       |
| `route=piste`                                                                | Route relation grouping piste sections                                  | Candidate                                                       |
| `piste:type=downhill`                                                        | Lift-served alpine skiing                                               | Excluded — not human-powered                                    |

## Hiking

Overlaps with tags already in the "sights" tables above — `natural=peak`, `cave_entrance`, `spring`, and `tourism=viewpoint` double as hiking waypoints, not just cycling-route POIs. Listed here for the hiking-specific difficulty/marking/network layer on top of that.

| Tag | Description | Status |
|---|---|---|
| `sac_scale=hiking` … `difficult_alpine_hiking` (6-step scale) | Swiss Alpine Club difficulty grading, easiest to most technical | Candidate |
| `trail_visibility=excellent` … `no` | How easy the trail is to follow on the ground | Candidate |
| `route=hiking` / `route=foot` | Route relation for a hiking trail | Candidate |
| `network=lwn`/`rwn`/`nwn`/`iwn` | Local/regional/national/international walking network | Candidate — parallel to the `lcn`/`rcn`/`ncn` cycling networks above |
| `trailblazed=yes`, `osmc:symbol=*` | Physical trail marking / blaze symbol | Candidate (minor) |
| `ford=yes`/`stepping_stones` | Stream/river crossing on the trail | Routability constraint |
| `safety_rope=yes`, `ladder=yes`, `rungs=yes` | Installed technical aids on exposed terrain | Candidate (minor) — safety content |
| `natural=saddle`/`ridge`/`arete`/`valley` | Terrain features beyond what's already in the sights table | Candidate |
| `mountain_pass=yes` | High point of a mountain-pass crossing | Candidate |

## Rock & Ice Climbing (bonus — "any other human-powered outdoor activity")

OSM's climbing schema is deep — route-level bolt counts, per-region grading systems, hazard flags. Summarized here at site level only; full route-level detail would be its own reference document if this ever became real.

| Tag | Description | Status |
|---|---|---|
| `sport=climbing` | Marks a site as having climbing | Candidate |
| `climbing=crag` | Small area with multiple climbing routes | Candidate — the POI-level tag, most useful as a "worth a stop" marker |
| `climbing=boulder` | Bouldering site (no rope) | Candidate |
| `climbing=area` | Larger region containing multiple crags | Candidate (minor) |
| `natural=cliff`/`rock`/`stone` + `sport=climbing` | The underlying natural feature a crag sits on | Candidate — `natural=cliff` already appears in the sights table above |
| `climbing:grade:*` (french/uiaa/yds_class/hueco/etc.) | Route-level grading, multiple regional systems | Excluded from this reference — route-level detail, not site-level content |
| `climbing:access=*` | Legal/seasonal access restrictions (e.g. raptor-nesting closures) | Routability constraint if ever surfaced |

## Open items

- ~~No region-specific validation yet~~ — **done for the paddling section only** (SPIKE-04, 2026-08-14): counts per region are in `spikes/SPIKE-04/results/RESULTS.md`, and the "rare-to-absent" worry was justified — the whitewater difficulty tags are absent outright. **The cycling, hiking, nordic, and climbing sections are still unvalidated** against these regions and still need the same taginfo/extract pass before anything is wired into the core.
- "Candidate (caution)" tags need a concrete filter rule (name-tag required, `denotation=` for trees, minimum park size, etc.) before they're usable — flagged, not resolved.
- Ties into FR23 (building/architectural interest theme) and the Leg 6 content-layer direction in `rebrand-plan.md` — this file is the tag-level detail underneath that decision, not a replacement for it.
- The greenway/rail-trail tagging pattern described above (highway + surface + name, no dedicated key) is inferred from general OSM tagging convention, not confirmed against this project's actual extracts — verify before relying on it to detect greenways programmatically.
- Routing-input tags here overlap with FR3 (lowest-traffic) and FR12 (surface-type scoring) — this file catalogs the tags: deciding how they fold into those themes' actual weight functions is separate, unstarted work.
- POI-candidate cyclist amenities (repair stations, parking, bike shops) aren't attached to any FR yet — closest existing hook is FR14's lodging-style provider pattern in `providers.py`, but no functional requirement currently covers "cyclist support amenities" as a category.
- MTB, paddling, nordic skiing, hiking, and climbing have zero existing FR/theme coverage — everything under "Other Human-Powered Outdoor Activities" is pure gathering per the broadened brief, not a scoped feature.
- Regional fit varies a lot by activity and hasn't been checked, **except paddling, which now has been**: the guess that "paddling is plausible in NC" was right about the *rivers* and wrong about the *data*. Western NC has the whitewater and OSM carries none of its grading. Nordic skiing, climbing, and MTB regional fit are still unchecked.
- **OSM is not the paddling network source.** SPIKE-04 found USGS NHDPlus HR carries roughly twice the paddleable-scale river length in the same bboxes, with declared topology and flow direction, where OSM has neither — and OSM has no equivalent of NHD's artificial paths across lakes, which is why a third of Western NC's mapped boat ramps sit up to 3 km from anything a router would consider water. The tags above stay useful for **access points, hazards, and `canoe=*` legality**; the graph itself comes from elsewhere (ARCH §6.4, §13.2).
- If any of these activities becomes a real mode rather than reference material, it likely needs its own `WeightProfile`/theme set analogous to the five cycling themes, not a bolt-on to the existing ones — rivers, singletrack, piste, and trails are structurally different routing graphs from roads.
