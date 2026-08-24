Your Journey, your story.  

Planning a journey is much like planning to write a story. You have your characters, friends that are going with you. The setting, where you are going and what you will see. Then a plot, a route to follow. 

Creating a good story has an arc to it, establishing the characters, key points that make things interesting, some struggle or obstacle to over come, then a conclusion where the characters reach a stopping point. 

Plotlines enables multi-modal adventure trips that include cycling, hiking, paddling, cross-country skiing, climbing, packrafting, riverboarding, canyoneering, jumar. . . different ways to get your self from here to there. 

Getting there is part of the fun, sometimes the last mile to the trailhead or put-in is the most harrowing moment of the day. Routes for auto trips and notes for train and plane transport are easy to access.

Trip authors bring their expertise, deep knowledge of how group dynamics influence an experience, and personal flair to the adventure. From a rest stop at a historic clock tower, a cycling leg with a bit of hiking to a scenic overlook, to a rest day where the lodging is convenient to a hot springs, sauna and a supermarket. Authors are the most important person in creating the outline of the story. 

Characters embark on the journey, they sync the plan to their mobile device app, view a webpage, or even create a paper print out of the routes, itineraries, cue sheets, POI notes, and author's plot points. Characters export daily routes to their prefered navigation device or application. Be it Garmin, Coros, RideWithGPS, or other application that accepts a GPX, FIT, or TCX input. 

## User Stories
---

### Author/Planner

As an author, I shall have the ability to create adventures that are single day, multi-day, or multi week so that i can tailor the total trip days to accommodate the character's time schedules. 

As an author I shall have the ability to create a route with a start point, endpoint and mode of travel so that I create designated segments for a given mode of travel.

As an author I shall have the ability to associate a route with a day, in a specified order, so that I full day can include segments containing different modes of travel. 

As an author I shall have the ability to set way points, and regroup points so that characters traveling at different rates can have a designated rally point.

As an author I shall have the ability to set rest stops based on the clustering of my selected amenities so that the services availile meet the needs of my group. 
- Scenario 1: an early rest stop only needs toilet facilities and drinking water. 
- Scenario 2: a mid-day rest stop includes a convenience store or cafe as well as toilet and drinking water services.
- Scenario 3: a late day rest stop includes a shelter so that characters can get out of the sun, toilet, drinking water, and a point of interest for early riders to enjoy while the rest of the group catches up. 
- Scenario 4: on a paddling trip the rest stop is designated at the beginning or end of a portage which includes a permitted campfire area so that the group can prepare a group shore lunch. 

As an author i shall have the ability to include additional information on points of interest, way points, rest stops, start and end points, and any other nodes so that characters will have my instructions, notes or highlights available to them when they are at the node. 

As an author I shall have the historic weather of the location of the segment i am working on displayed with a box and whisker chart of the last 5 years of temperature values, were the all time low and all time high are the ends of the graph. 

As an author i shall have the ability to select advanced weather history to display precipitation volume and type, as well as additional 10 year distribution graph history of temperature values for plus 3 and minus 3 days of the date being scheduled. 

As an author I shall have the ability to set start days, end days, and rest days (zero days) based on the clustering of amenities in the area.

As an author of a cycling segment I shall have the ability to weight route preferences for climbing, traffic, lack of or density of points of interest, and surface (paved vs gravel vs single track), to set the tone of the day. 
- Scenario 1: an early segment is weighted 5 out of 5 peaks to front load climbing while riders are fresh. 
- Scenario 2: the second day of a multi-day tour is in an area of many waterfalls, the author wants to include as many as they can while keeping the day milage goals reasonable. 
- Scenario 3: the final day of a trip is set to 0 of 5 peaks to accommodate tired legs. 
- Scenario 4: the first day of a trip starts in a large city the author sets the traffic scale at 2.5 out of 5 cars to allow for routes that includes some busy sections to get riders out of town in an expedient manner. 

As an author I shall have the ability to select which lodging types i would like to see plotted on the map so that I can match the accommodations to the needs of my characters. 

As an author I shall have the ability to set the buffer distance of an entire trip so that the characters have enough information without causing large downloads.

As an author I shall have the ability to set the group size to a single character, a small group (2-9), a party/club (10 to 49), a large group (50 to 99), or an Organized Event (100 +)

As an author I shall have the ability to see characters submitted preferences (elevation or grade gains for cycling and hiking, river rating or gauge height for paddling, traffic, trail types, surface, point of interest density, preferred distance per day, typical travel speed, and so on) so I can match routes and day planning with the preferences of the whole group. 

---


Character/Adventurer

As a character I shall have the ability to have a full local version of the buffer area of an entire trip so that I can see adjacent points of interest or do minor re-routes that fit my needs when my mobile app does not have a network connection. 

As a character I shall have the ability to select my weighting preferences on the route parameters the author has selected as variable for this trip. 







----
## Core Trip Definition

### Story 1: Define Adventure Duration & Timeframe

**As an** Author

**I want to** define the total duration of an adventure (single-day, multi-day, or multi-week)

**So that** I can tailor the trip structure to fit my group's time constraints.

**Acceptance Criteria:**

- Author can set a start date, end date, or total number of days for an adventure.
    
- The system supports single-day, multi-day, and multi-week durations.
    
### Story 9: Start, End, and Rest Days

**As an** Author

**I want to** designate specific days as Start Days, End Days, or Rest/Zero Days

**So that** I can pace the trip around nearby lodging and amenity clusters.

**Acceptance Criteria:**

- Author can mark any day in the trip itinerary as a Start, End, or Rest/Zero day.
    
- Rest/Zero days preserve location without requiring active route segments.

    
- Rest/Zero days can contain points of interest, itinerary details, and scheduled events.

    
## Multimodal Routing & Transitions
### Story 2: Create Multi-Modal Route Segments

**As an** Author

**I want to** create a route segment with a defined start point, end point, and primary travel mode

**So that** I can designate distinct paths for different types of movement (e.g., cycling, paddling, hiking).

**Acceptance Criteria:**

- Author can place/select a start node and an end node.
    
- Author can select a travel mode for the segment from a supported list.
    
- The segment is saved with its start point, end point, and assigned mode.
    

### Story 3: Order Segments Within a Day

**As an** Author

**I want to** assign and sequence route segments within a specific calendar day

**So that** a single day can incorporate multiple travel modes in a specific logical order.

**Acceptance Criteria:**

- Author can assign one or more created segments to a specific day of the trip.
    
- Author can reorder segments within a day to define the transition sequence.
    
- Author gets warning when adjacent segment start and end points fall more than 500 meters apart. 

### Story 15: Create Multimodal Transition Points

**As an** Author

**I want to** define Transition Nodes between different modes of travel

**So that** characters know where to switch activities, stash/retrieve gear, or execute put-ins and take-outs.

## Waypoints, Rest Stops & Nodes
### Story 4: Designate Waypoints and Regroup Points

**As an** Author

**I want to** mark specific waypoints and regroup points along a route

**So that** participants traveling at different paces have pre-planned rally locations.

**Acceptance Criteria:**

- Author can place waypoints directly on a route segment.
    
- Author can designate a waypoint specifically as a "Regroup Point."
    

### Story 5: Set Rest Stops Based on Amenity Clusters

**As an** Author

**I want to** mark rest stops along a route based on available local amenities

**So that** the group's mid-route logistical and physical needs are met.

**Acceptance Criteria:**

- Author can place rest stops on a route segment.
    
- Author can tag or view available amenities (e.g., water, toilets, food, shelter) at each rest stop location.
    

### Story 6: Attach Author Notes & Highlights to Nodes

**As an** Author

**I want to** attach custom instructions, notes, and photos/highlights to points of interest, waypoints, rest stops, and route endpoints

**So that** characters have contextual guidance available when they reach that location.

**Acceptance Criteria:**

- Author can add rich text notes/instructions to any node (POI, waypoint, rest stop, start/end).
    
- Saved notes are associated directly with that node for participant viewing.
    
## Domain-Specific Routing Weights & Parameters

### Story 10: Preference Weights - All selections

As an Author designing a segment

I want to select a minimum and maximum weight of a given type. 

So that the routing engine can offer good compromises of multiple preferences

### Story 10a: Set Climbing Preference Weight ("Peaks")

**As an** Author designing a cycling, climbing or hiking segment

**I want to** adjust the climbing preference on a 0.0 to 5.0 scale (represented as "peaks")

**So that** I can control the amount and density of elevation gain for the day (e.g., setting 5.0 peaks to front-load climbing or 0.0 peaks for flat recovery days).

**Acceptance Criteria:**

- The climbing weight control uses a 0.0 to 5.0 scale with decimal precision (e.g., supporting inputs like 2.5).
    
- The UI represents this preference using "peaks" terminology.
    
- The routing engine prioritizes or avoids elevation gains relative to the selected peak rating while adhering to origin and destination points.



    

### Story 10b: Set Traffic Preference Weight ("Cars")

**As an** Author designing a cycling or hiking segment

**I want to** set a traffic tolerance weight on a 0.0 to 5.0 scale (represented as "cars")

**So that** I can balance rider safety and quiet roads against direct egress out of urban areas.

**Acceptance Criteria:**

- The traffic weight control uses a 0.0 to 5.0 scale supporting decimal values (e.g., 2.5 cars to allow necessary urban arterial links).
    
- The UI represents this preference using "cars" terminology.
    
- The routing engine factors vehicle density/road classification thresholds based on the designated car score.
    

### Story 10c: Set Point of Interest Density & Mileage Targets

**As an** Author designing any segment

**I want to** set POI density preference weights alongside a target daily mileage range

**So that** the routing engine maximizes scenic/cultural stops without exceeding reasonable distance goals for the group.

**Acceptance Criteria:**

- Author can specify a daily mileage goal (target min/max distance).
    
- Author can adjust POI density weighting on a 0.0 to 5.0 scale.
    
- The routing engine attempts to draw a path that maximizes high-value POIs (e.g., waterfalls, overlooks) while remaining within the defined mileage envelope.
    

### Story 10d: Set Surface Type Distribution

**As an** Author designing a cycling, hiking, or portage segment

**I want to** set weighting preferences for surface types (paved, gravel, singletrack)

**So that** the route aligns with the group's equipment capabilities and desired ride character.

**Acceptance Criteria:**

- Author can adjust relative preference weights on a 0.0 to 5.0 scale for paved roads, gravel/unpaved roads, and singletrack trails.
    
- The routing engine favors road types matching the highest-weighted surface preferences.

### Story 10e: Set Difficulty Preference for WhiteWater
As an Author designing a paddling segment

I want to set weighting preferences for whitewater ratings

So that the characters are routed to dangerous sections that exceed their abilities

### Story 10f: Set Water type preferences

As an Author designing a paddling segment

I want to set weighting preferences for flatwater to whitewater

So that the trip segment aligns with my trip goals and equipment selections


### Story 18: Set Water and Technical Difficulty Parameters

**As an** Author designing paddling or technical land segments

**I want to** define minimum and maximum river gauge heights, water class ratings, or terrain technicality/exposure scales

**So that** route options match the technical abilities of the group.

_Acceptance Criteria:_ Define class ratings (e.g., Class I–V) and gauge thresholds for paddle/technical segments.


## Weather & Environmental Planning

### Story 7: View Basic Historical Temperature Data

**As an** Author

**I want to** view 5-year historical temperature ranges (box-and-whisker plot) for my active route segment

**So that** I can anticipate expected climate conditions during planning.

**Acceptance Criteria:**

- Display a box-and-whisker plot of temperature values for the segment's location over the past 5 years.
    
- The visualization displays the all-time high and all-time low as the ends of the graph.
    

### Story 8: View Advanced Weather History & Variations

**As an** Author

**I want to** view expanded weather history including precipitation volume, type, and a 10-year temperature distribution for ±3 days of the target date

**So that** I can evaluate potential weather extremes and precipitation risks during planning.

**Acceptance Criteria:**

- Author can toggle advanced weather view for a segment date.
    
- Display precipitation volume and type for the selected timeframe.
    
- Display a 10-year distribution graph covering 3 days before and 3 days after the planned date.
    


## Group Mechanics, Lodging & Maps


### Story 11: Filter Lodging Amenities on Map

**As an** Author

**I want to** filter and display specific lodging types on the planning map

**So that** I can select accommodations that fit my group's requirements.

**Acceptance Criteria:**

- Map controls allow filtering visible lodging types (e.g., campsites, hotels, huts, hostels).
    
- Map overlays update dynamically based on active lodging filters.
    

### Story 12: Set Offline Data Buffer Distance

**As an** Author

**I want to** specify the geographical buffer distance around the trip route for offline map downloads

**So that** characters receive sufficient surrounding map context without downloading excessively large files.

**Acceptance Criteria:**

- Author can enter or select a corridor/buffer distance (e.g., miles or kilometers from route center).
    
- The set buffer distance is saved as a download parameter for the adventure package.
    

### Story 13: Define Target Group Size

**As an** Author

**I want to** set the intended group size category for an adventure

**So that** logistics, rest stops, and lodging choices align with group scale.

**Acceptance Criteria:**

- Author can select one group size tier: Solo (1), Small (2–9), Party/Club (10–49), Large (50–99), or Organized Event (100+).
    
- Selected group size is saved to the adventure metadata.
    
### Story 29: Model Mode and Terrain-Specific Travel Speeds in Planning Metrics

**As an** Author

**I want to** configure estimated travel speeds by mode and terrain type (e.g., pavement cycling speed vs. singletrack, flat paddling vs. swiftwater, steep hiking ascent rate)

**So that** the planning metrics dashboard accurately calculates realistic segment moving times, total day duration, and arrival estimates.

**Acceptance Criteria:**

- Author can define or adjust base speed parameters for specific travel modes and surface/terrain variations (e.g., pavement vs. gravel/singletrack, flat vs. steep grade adjustments, flatwater vs. moving water).
    
- Author can choose whether to apply a default system pace, the Author's custom pace profile, or the aggregated speed profile of the participating characters.
    
- The real-time planning dashboard (from Story 21) dynamically updates estimated moving time, total elapsed time (including rest/regroup stops), and estimated time of arrival (ETA) at key nodes based on active mode/terrain speeds.
    
- Segment and daily itineraries explicitly present expected elapsed time alongside distance and elevation metrics.
### Story 14: Review Aggregated Group Preferences

**As an** Author

**I want to** view submitted character preferences for physical, technical, and environment parameters

**So that** I can design routes and daily plans that suit the collective capabilities and desires of the group.

**Acceptance Criteria:**

- Display aggregated character preferences (e.g., elevation gain tolerance, river ratings, preferred daily distance, travel speed, preferred surface types, traffic tolerance).
    
- Preference summary is accessible within the Author planning dashboard.
    
- Aggregations display Min, Max, Avg, and Mode for all group sizes
    
- Histogram displayed for groups larger than 10 characters
    
- Only preferences that align with travel modes for the entire trip are displayed



### Story 29: Model Mode and Terrain-Specific Travel Speeds in Planning Metrics

**As an** Author

**I want to** configure estimated travel speeds by mode and terrain type (e.g., pavement cycling speed vs. singletrack, flat paddling vs. swiftwater, steep hiking ascent rate)

**So that** the planning metrics dashboard accurately calculates realistic segment moving times, total day duration, and arrival estimates.

**Acceptance Criteria:**

- Author can define or adjust base speed parameters for specific travel modes and surface/terrain variations (e.g., pavement vs. gravel/singletrack, flat vs. steep grade adjustments, flatwater vs. moving water).
    
- Author can choose whether to apply a default system pace, the Author's custom pace profile, or the aggregated speed profile of the participating characters.
    
- The real-time planning dashboard (from Story 21) dynamically updates estimated moving time, total elapsed time (including rest/regroup stops), and estimated time of arrival (ETA) at key nodes based on active mode/terrain speeds.
    
- Segment and daily itineraries explicitly present expected elapsed time alongside distance and elevation metrics.
## Route Variation & Evaluation Tools
### Story 16: Assign Narrative Plot Points & Trip Arc

**As an** Author

**I want to** tag specific route locations or segments with narrative arc stages (e.g., Exposition, Crux/Obstacle, Climax, Resolution)

**So that** the experience follows a structured storytelling format.

### Story 17: Add Transit and Access Segments

**As an** Author

**I want to** build access/transit legs (auto drive, train, shuttle, or plane links) leading to trailheads or put-ins

**So that** characters have end-to-end travel logistics in one place.

Acceptance Criteria: Transit legs support identifiers (bus route, flight number, carrier), scheduled times, hyperlinks to carrier or transit authority website.
Characters can opt-in to share details with author for personal travel arrangements.



### Story 19: Define Alternate Route Options

**As an** Author designing an active route segment

**I want to** attach alternate route paths (e.g., bypasses for technical/strenuous sections, or optional mileage extensions)

**So that** individual characters can choose an option that matches their physical condition or skill level without leaving the trip framework.

**Acceptance Criteria:**

- Author can designate a secondary path linked to a primary segment as an "Bypass/Easiest" or "Extension/Challenge" option.
    
- Alternate routes can be defined across any supported travel mode (e.g., land, paddle, or climbing routes).
    
- The system tags alternate routes clearly so characters can view both options on maps and cue sheets.
    

### Story 20: Define Daily Distance Boundaries by Mode

**As an** Author designing daily itineraries

**I want to** set minimum and maximum distance thresholds for each travel mode within a given day

**So that** the total daily effort remains within the group's planned limits.

**Acceptance Criteria:**

- Author can enter minimum and maximum distance targets per travel mode for any selected day.
    
- The system displays an indicator or warning during route selection if an active segment falls below the minimum or exceeds the maximum threshold for that mode.
    

### Story 21: Real-Time Planning Metrics Dashboard

**As an** Author designing an adventure

**I want to** view real-time distance and elevation gain metrics broken down by segment, day, total trip, and travel mode

**So that** I can immediately evaluate the physical impact of route adjustments as I build the plan.

**Acceptance Criteria:**

- A persistent planning panel displays:
    
    - Active segment distance and elevation gain/loss.
        
    - Current day total distance and elevation gain/loss (broken down by mode).
        
    - Entire trip cumulative distance and elevation gain/loss (broken down by mode).
        
- Metrics update dynamically whenever a segment is added, edited, or reordered.

### Story 22: Multi-Route Elevation Profile Comparison

**As an** Author designing a route segment with alternate options

**I want to** view overlapping elevation profiles for all active route choices in a single comparison view

**So that** I can compare total climbing, steepness, and elevation trends without toggling back and forth between options.

**Acceptance Criteria:**

- The elevation chart can render the primary route and all associated alternate/bypass routes simultaneously in a single view.
    
- Each route option is visually distinguished (e.g., color-coded line overlays).
    
- Hovering/scrubbing along the profile highlights the corresponding point on the map for all displayed route options.
    

### Story 23: Define Portages and Water Trail Connections

**As an** Author designing a paddling segment

**I want to** explicitly define portages and water trail links with egress side and trail characteristics

**So that** characters have clear instructions for exiting the water and navigating land transitions.

**Acceptance Criteria:**

- Author can place a portage transition on a paddle segment, designating the exit bank (e.g., river left / river right).
    
- Portage metrics—including portage distance, trail surface, and elevation change—are calculated and displayed separately from water distances.
    
- Mandatory portages (e.g., around dams or hazardous waterfalls) can be flagged with a prominent warning status.
    
- Portages are automatically included in generated cue sheets, daily itineraries, and route summaries.
    
- Portage entry/exit nodes can be designated as Rest Stops, Waypoints, or Regroup Points with attached author notes.

### Story 27: Assign Hazard and Technical Crux Warnings

**As an** Author

**I want to** place hazard indicators and technical crux warnings on route segments, access roads, transition points, or water legs

**So that** characters are clearly alerted to high-risk terrain, difficult vehicle access, or dangerous obstacles before and during the trip.

**Acceptance Criteria:**

- Author can attach a "Hazard Warning" or "Technical Crux" marker directly to any point along an active route, transit leg, or node (e.g., unmaintained gravel access roads, high-exposure scrambles, Class IV rapid sections, unbridged river crossings).
    
- Author can assign a severity level (e.g., Caution, High Hazard, Mandatory Re-route/Crux) and add explanatory safety notes or required gear callouts (e.g., high-clearance 4WD required, helm required, throw rope mandatory).
    
- Hazard warnings are highlighted visually on the planning map, elevation profiles, daily itineraries, and generated cue sheets.
    
- High-severity hazard markers trigger a distinct alert within the mobile app when synced to characters' devices.

### Story 28: Embed Scheduled Events into Daily Itineraries

**As an** Author

**I want to** schedule time-bound events (such as evening concerts, guided tours, timed ferry crossings, or museum bookings) into a specific day’s plan

**So that** daily routing, rest stops, and arrival expectations align with fixed event schedules.

**Acceptance Criteria:**

- Author can create a "Scheduled Event" node associated with a specific date and time window (start time, end time/duration, location).
    
- Scheduled events can be attached to mid-route nodes (e.g., lunch-break tours, timed shuttle/ferry connections) or day-end nodes (e.g., evening concerts, dinners).
    
- The planning timeline displays fixed event times alongside estimated travel arrival times, flagging scheduling conflicts if planned segment speeds will cause the group to miss the event window.
    
- Scheduled events, including start times and venue notes, are automatically populated on group itineraries, daily cue sheets, and mobile app timeline views.

## Outputs, Cue Sheets & Exports

### Story 24: Generate Master Group Itinerary

**As an** Author designing a trip

**I want to** generate a full or multi-day trip itinerary for the entire group

**So that** I can review the overarching schedule and share offline/printable summaries with participants.

**Acceptance Criteria:**

- Author can select specific days or export the complete adventure timeline into a master group itinerary document.
    
- The itinerary aggregates daily start/end points, routes, travel modes, POIs, rest stops, and lodging notes.
    
- The generated itinerary can be previewed, printed, or exported (e.g., PDF) for sharing outside the application.
    

### Story 25: Generate Tailored Individual Itineraries

**As an** Author managing group logistics

**I want to** generate customized individual itineraries for specific characters

**So that** participants joining late, leaving early, or taking personalized transit legs have accurate personal plans.

**Acceptance Criteria:**

- Author can adjust start/end dates and transit nodes on a per-character basis.
    
- The system generates a personalized itinerary reflecting only the specific days, segments, and logistics assigned to that individual character.
    
- Individual itineraries retain author notes and POI data relevant to that character's selected route options.
    

### Story 26: Generate Daily Cue Sheets

**As an** Author designing daily route segments

**I want to** generate turn-by-turn cue sheets for any selected day

**So that** characters can access structured navigation cues digitally or via paper printouts.

**Acceptance Criteria:**

- Author can generate cue sheets on a per-day basis containing turn-by-turn directions, distances, surface transitions, and node highlights.
    
- Generated cue sheets automatically sync to the Character's mobile app for offline viewing.
    
- Author can export and print single-day cue sheets (including batch printing multiple copies for group distribution).

### Story 31: Dual-Role Activation (Author as Participating Character)

**As an** Author who is also participating in an adventure

**I want to** activate my own Character profile for a trip I am planning

**So that** I receive participant-level offline package downloads, live navigation cues, personal device sync, and character metrics without needing a second user account.

**Acceptance Criteria:**

- Author interface includes a simple "Participate as Character" toggle during trip setup.
    
- When toggled ON, the system automatically generates a Character profile for the Author and includes them in group preference aggregations, lodging headcounts, and group size calculations.
    
- The Author's mobile app seamlessly merges Author management tools (e.g., editing notes or updating regroup points on the fly) with Character execution views (e.g., offline vector map downloads, turn-by-turn cue sheets, device sync, and field logging).
    
- Generated group rosters, cue sheets, and exported individual itineraries properly list the Author as a active participant.

### Story 32: Multimodal Group & Personal Gear Checklist

**As an** Author

**I want to** create mode-specific gear lists (mandatory safety gear, group shared equipment, and individual gear checklists)

**So that** characters know exactly what required gear to pack for each multimodal segment.

**Acceptance Criteria:**

- Author can attach mandatory and recommended gear lists to specific travel modes (e.g., PFD, throw rope, dry bag for paddle segments; helmet, repair kit for cycling).
    
- Author can designate items as "Shared Group Gear" (e.g., stove, water filter, satellite messenger) and assign them to specific characters.
    
- Characters can view their consolidated packing list (personal + assigned group gear) in their app and check off items prior to departure.
    

## 3. The "Food, Water & Resupply Logistics" Gap

For multi-day or multi-week backcountry journeys, managing water treatment points, resupply stops, and group meals is critical.

### Story 33: Designate Water Sources, Resupply Points & Group Meals

**As an** Author

**I want to** mark potable water availability, raw water filtration points, food resupply locations, and group meal responsibilities on the itinerary

**So that** characters can manage their hydration and nutrition capacity between supply points.

**Acceptance Criteria:**

- Author can place "Water Point" nodes along segments, tagging them as _Potable Water_ (tap/fountain) or _Filter Required_ (stream/lake).
    
- Author can place "Resupply Points" (post office for mail drops, grocery stores) with operating hours and notes.
    
- Daily itineraries display estimated water carry distances between designated water sources.
    

## 4. The "Permits, Land Access & Passes" Gap

National parks, wilderness areas, river corridors, and private land connections frequently require permits, parking passes, or entry fees.

### Story 34: Land Access, Permits, and Parking Pass Tracking

**As an** Author

**I want to** attach permit requirements, lottery deadlines, land access restrictions, and parking pass rules to specific segments or parking nodes

**So that** characters obtain the necessary legal permissions and passes prior to arrival.

**Acceptance Criteria:**

- Author can tag segments or nodes with permit statuses (e.g., _Permit Required_, _Self-Registration at Trailhead_, _Pass Required - e.g., Northwest Forest Pass_).
    
- Author can attach permit confirmation numbers, PDF documents, or link rules directly to the node.
    
- Characters receive a checklist of required permits and passes when viewing the pre-trip checklist.

### Story 35: In-the-Field Route Amendment (Offline Mobile Adjustment)

**As a**  User (Author or Character) executing a trip in the field

**I want to** modify a route segment or activate a pre-planned alternate bypass route on my mobile device while offline

**So that** my local navigation views, daily metrics, and turn cues update immediately when encountering real-time field obstacles (e.g., trail washouts or high water).

**Acceptance Criteria:**

- User can toggle active routes to pre-planned alternate/bypass routes or draw a quick route modification directly on the offline mobile app map.
    
- Modifying the route dynamically updates the local mobile app's active map layer, elevation profile, and generated turn-by-turn cue sheet.
    
- Updated route edits persist in local device storage and auto-sync to the cloud whenever cellular or Wi-Fi connectivity is restored.
- Use can select to publish route change to other group members

### Story 36: Receive and Evaluate In-the-Field Route Amendments

**As a** User (Author or Character) connected to a network

**I want to** receive notifications of route amendments published by another trip planner or participant, preview the changes, and choose to accept or decline the update

**So that** I can adopt necessary route changes while retaining control over my own path if the amendment is irrelevant to my current location or if an alternate route suits me better.

**Acceptance Criteria:**

- When an Author or trip participant publishes a route amendment, all connected characters on that trip receive an in-app notification detailing the change (e.g., _"John updated Day 2 Cycling Segment due to trail obstruction"_).
    
- Opening the notification displays a split-screen or side-by-side preview showing the **Current Route** vs. the **Proposed Route Amendment**, including updated distance, elevation, and hazard metrics.
    
- The user can select one of three actions:
    
    - **Accept Update:** Replaces the user's active route, maps, and cue sheet with the newly amended route.
        
    - **Decline Update:** Retains the user's existing route, maps, and cue sheet without modification.
        
    - **Select Alternate:** Allows the user to choose a different pre-planned alternate/bypass route instead of the proposed amendment.
        
- If a user declines or selects an alternate route, their individual itinerary and navigation cues update independently without disrupting the rest of the group's active choices.


## Character Stories

  

## Part 1: Character Counterparts to Author Capabilities

These stories mirror the corresponding Author capabilities (Stories 1–30), transforming planning rules into participant views, interactions, and sync capabilities.

### Story C1: View Master & Individual Trip Itineraries _(Counterpart to Author Stories 1, 24, 25)_

**As a** Character

**I want to** view my complete trip itinerary (or filtered individual schedule for partial attendance) across single-day, multi-day, or multi-week adventures

**So that** I understand the total scope, daily stages, lodging locations, and my specific arrival/departure timeline.

**Acceptance Criteria:**

- Character can view an end-to-end trip timeline on mobile or web.
    
- Displays personalized arrival/departure points if partial-trip dates were set by the Author.
    
- Displays daily start/end locations, overall distance, and primary travel modes.
    

### Story C2: Inspect Multimodal Daily Segments & Transitions _(Counterpart to Author Stories 2, 3, 15)_

**As a** Character

**I want to** review each day's route broken down by distinct travel modes and transition nodes

**So that** I know when, where, and how we are switching activities (e.g., parking vehicles, stashing bikes, launching paddlecraft).

**Acceptance Criteria:**

- Daily timeline clearly distinguishes mode changes (e.g., drive segment $\rightarrow$ transition node $\rightarrow$ bike segment $\rightarrow$ paddle segment).
    
- Transition nodes display specific Author instructions for stashing gear, vehicle parking, or equipment switches.
    

### Story C3: View Waypoints, Regroup Points & Rest Stop Amenities _(Counterpart to Author Stories 4, 5)_

**As a** Character

**I want to** view planned regroup points and amenity-rich rest stops on my daily map and cue sheet

**So that** I know where to rally with the group and what services (water, toilets, food, shelter) to expect along the way.

**Acceptance Criteria:**

- Regroup points are visually highlighted as mandatory or optional rally locations.
    
- Rest stop nodes display tagged amenities (e.g., potable water, cafe, shelter) and distance to next available amenity cluster.
    

### Story C4: Access Node Notes, Media & Story Highlights _(Counterpart to Author Stories 6, 16)_

**As a** Character

**I want to** tap any map node or narrative plot point to read the Author's rich text notes, instructions, or scenic highlights

**So that** I experience the historical, cultural, or narrative context curated for that location.

**Acceptance Criteria:**

- Tapping a node (POI, waypoint, rest stop, plot point) opens a rich content card (text, notes, photos).
    
- Narrative plot points (e.g., "The Crux", "Scenic Climax") are distinguished visually on the map and timeline.
    

### Story C5: Review Environmental & Weather Forecast Comparisons _(Counterpart to Author Stories 7, 8)_

**As a** Character

**I want to** view live weather forecasts when at 10 day forecast threshold overlaid against the Author's 5-year and 10-year historical climate baselines

**So that** I can pack appropriate gear and prepare for expected temperature ranges, wind, and precipitation.

**Acceptance Criteria:**

- Displays active multi-day forecast alongside historical temperature ranges for the specific route corridor.
    
- Highlights potential weather deviations (e.g., unseasonably cold temperatures or high precipitation risk).
    
- Live forecast does not remove or obscure historical data. 

- Live forecast has a short time limit cache expiry to show up to date information
    



### Story C6: Submit Personal Capability & Preference Profiles _(Counterpart to Author Story 14)_

**As a** Character

**I want to** submit my personal travel preferences and physical/technical thresholds (climbing tolerance, river class ratings, preferred daily distance, typical moving speed)

**So that** the Author can build trips matching my real-world capabilities.

**Acceptance Criteria:**

- Character profile includes inputs for: max preferred daily elevation/distance, cycling surface preference, comfort with vehicle traffic (cars), paddle river rating (Class I–V), and base flatland moving speeds.
    
- Profile settings populate automatically into the Author’s aggregated planning dashboard.
    

### Story C7: Select and Toggle Alternate Route Options _(Counterpart to Author Story 19)_

**As a** Character

**I want to** select between primary routes and Author-provided alternate options (e.g., technical bypasses or optional mileage extensions)

**So that** I can tailor a day's ride, hike, or paddle to my energy levels without losing navigation guidance.

**Acceptance Criteria:**

- Maps and cue sheets allow toggling between "Primary", "Bypass/Easy", and "Extension/Challenge" routes.
    
- Metrics (distance, elevation, ETA) update dynamically based on the selected route variation.
    

### Story C8: View Elevation Profiles and Multi-Option Comparisons _(Counterpart to Author Stories 21, 22)_

**As a** Character

**I want to** inspect elevation profiles for my daily routes and compare alternate options side-by-side

**So that** I understand steepness trends, total vertical gain, and upcoming climbs before starting the leg.

**Acceptance Criteria:**

- Profile chart highlights steep grade percentages and elevation gain.
    
- Scrubbing along the elevation profile tracks the exact position marker on the map view.
    

### Story C9: Inspect Portage & Technical Water Details _(Counterpart to Author Story 23)_

**As a** Character on a paddling trip

**I want to** view detailed portage callouts including exit bank (river left/right), land distance, trail surface, and hazard severity

**So that** I can safely execute water-to-land transitions and carry gear around impassable water features.

**Acceptance Criteria:**

- Portage alerts display exit side instructions, land carry distance, and trail grade.
    
- Mandatory portages (dams/waterfalls) render prominent safety banners in the mobile app and cue sheets.
    

### Story C10: Access Digital & Printable Daily Cue Sheets _(Counterpart to Author Story 26)_

**As a** Character

**I want to** access turn-by-turn cue sheets within the mobile app or print a formatted paper copy

**So that** I have reliable, step-by-step directional guidance regardless of mobile battery or screen visibility.

**Acceptance Criteria:**

- Interactive cue sheet lists turns, distances, surface shifts, and node highlights.
    
- Print-optimized layout fits clean, readable cue cards onto standard paper sizes.
    


    

### Story C12: View Scheduled Events in Daily Timeline _(Counterpart to Author Story 28)_

**As a** Character

**I want to** view fixed, time-bound events (e.g., evening concerts, guided tours, timed ferry departures) integrated into my daily route timeline

**So that** I know when I need to reach key checkpoints to arrive on time.

**Acceptance Criteria:**

- Timed events appear in chronological order alongside segment moving times.
    
- Displays live ETA countdown based on current location and travel pace.
    

## Part 2: Character-First Execution & Narrative Stories

These stories focus on the **Character's primary user journey**: offline mobile execution, multi-device hardware export, offline maps, live progress tracking, and personal narrative contributions.

### Story C13: One-Tap Offline Trip Data Download

**As a** Character embarking on a wilderness trip

**I want to** download the complete adventure package (vector maps, routes, cues, notes, POIs, and buffer zones) to my mobile device prior to departure

**So that** I have full navigation and narrative capability in areas with zero cellular connectivity.

**Acceptance Criteria:**

- Single "Download for Offline Use" button packages all daily routes, cue sheets, node media, and vector topographic basemaps within the Author's specified corridor buffer distance.
    
- Complete functionality (search, cue tracking, narrative reading, map rendering) works cleanly in airplane mode.
    

### Story C14: Multi-Device Ecosystem Export (GPX / FIT / TCX)

**As a** Character who uses dedicated sports hardware

**I want to** export individual daily routes or multi-day plotlines to my preferred device format (GPX, FIT, TCX) or third-party platforms (Garmin, Coros, Wahoo, RideWithGPS)

**So that** I can navigate using my existing bike computer or GPS watch.

**Acceptance Criteria:**

- Export interface supports downloading standard `.GPX` (tracks & waypoints), `.FIT` (courses with turn cues), and `.TCX` (courses with custom plot point notes) files.
    
- Supports direct sync integration with major ecosystem APIs (Garmin Connect, Coros, Wahoo, RideWithGPS).
    
- Export preserves custom Author waypoints, regroup markers, and rest stop names as native turn/course points on head units.
    


C15 moved to backlog

C16 moved to backlog



### Story C17: Log Character Field Notes, Photos & Journal Entries

**As a** Character completing a trip segment

**I want to** attach personal field notes, photos, and voice snippets to route nodes or specific trip days

**So that** I can capture my personal experience alongside the Author's plotlines.

**Acceptance Criteria:**

- Character can attach personal photos/text notes to any node or GPX track coordinate during or after a trip.
    
- Personal entries remain private to the character or can be shared with the trip group.
    
- Local copies are stored on device first, then synced to cloud to ensure the local copy is intact in areas of unreliable network connectivity
    

### Story C18: Post-Trip Experience Summary & Performance Metrics

**As a** Character finishing an adventure

**I want to** view an aggregated post-trip summary comparing my actual moving time, distance, and recorded tracks against the Author's original plan

**So that** I can review my accomplishments and archive my journey narrative.

**Acceptance Criteria:**

- Generates a "Trip Recap" comparing planned vs. actual distance, moving time, and elevation gain by travel mode.
    
- Combines Author narrative points with Character-logged photos/notes into a digital souvenir journey record.

### Story C19: Outdoor High-Contrast Display & Ergonomic Map Controls

**As a** Character navigating outdoors

**I want to** toggle a High-Contrast Outdoor display mode and access primary map controls within the lower-screen thumb zone

**So that** I can read maps in direct sunlight and navigate the UI one-handed.

### Story C20: Dead-Zone Odometer Mode for GPS Signal Loss

**As a** Character who loses GPS signal in dense cover or canyons

**I want the** mobile app to hold my last known map position and allow manual mileage scrolling on the daily cue sheet

**So that** I can continue navigating by landmark and distance markers until GPS connectivity is restored.
## System & Platform User Stories ("Any User")

### Story S1: Configure Display & Measurement Preferences

**As a** User (Author or Character)

**I want to** configure my preferred display units and theme settings

**So that** all distances, temperatures, maps, and UI elements align with my personal standards and viewing preferences.

**Acceptance Criteria:**

- User can toggle distance units between **Miles** and **Kilometers**.
    
- User can toggle temperature units between **Fahrenheit (°F)** and **Celsius (°C)**.
    
- User can toggle application appearance between **Light Mode**, **Dark Mode**, or **System Default**.
    
- Selected preferences immediately update all elevation charts, cue sheets, planning dashboards, maps, and weather widgets across web and mobile apps.
    

### Story S2: Manage User Profile & Home Location

**As a** User

**I want to** set up and edit my basic profile details (nickname, email address, phone number, and free-text home location)

**So that** group rosters, contact summaries, and default routing origins reflect my information.

**Acceptance Criteria:**

- Profile management interface provides inputs for: **Nickname**, **Email Address**, **Phone Number**, and **Home Location** (free-text string, e.g., "Seattle, WA" or "123 Main St").
    
- Email address validation ensures correct formatting.
    
- Profile details are saved to the user account and populate relevant group contact lists and participant rosters.
    

### Story S3: Automatic Local GeoJSON Trip Backups

**As a** User creating or editing an adventure

**I want the system to** automatically save local background backups of trip data in GeoJSON format to my local device storage

**So that** my trip geometries, routes, and node edits are protected against network drops or application crashes.

**Acceptance Criteria:**

- The application periodically auto-saves the active trip’s spatial layers (routes, alternate paths, waypoints, rest stops, transition nodes, hazards) as valid `.geojson` objects in local device/browser storage.
    
- Local backups trigger upon key editing events (e.g., segment addition, waypoint move, node save) or at regular intervals during active editing.
    
- GeoJSON schema adheres to standard RFC 7946 specification with custom feature properties for node types, modes, and metadata.
    

### Story S4: Automatic Markdown Formatting for Field Notes, Photos, and Journals

**As a** Character or Author adding field notes, journal entries, or photos

**I want the system to** automatically format and store notes and photo logs as structured Markdown documents

**So that** my personal observations and media remain human-readable, portably linked, and cleanly styled.

**Acceptance Criteria:**

- Field notes, journal entries, and node highlights are saved as valid `.md` (Markdown) text files.
    
- Image attachments are saved as local binary references and embedded into the Markdown document using standard relative image syntax (e.g., `![Photo Caption](./photos/photo_001.jpg)`).
    
- Web links, GPS coordinates, and node references added within notes are rendered using standard Markdown hyperlink syntax (`[Link Text](URL)`).
    

### Story S5: Export Complete Trip Backup Archive (.zip)

**As a** User

**I want to** export an entire trip as a standalone `.zip` archive containing Markdown documents, GeoJSON geometries, GPX/TCX tracks, and raw photo binaries

**So that** I have a complete, offline-portable, vendor-neutral backup of my entire adventure package.

**Acceptance Criteria:**

- Export action packages the active trip into a single downloadable `.zip` file.
    
- The `.zip` archive structure includes:
    
    - `/routes` – Complete `.geojson`, `.gpx`, and `.tcx` files for all primary and alternate segments.
        
    - `/journal` – Markdown (`.md`) files for all author notes, daily itineraries, cue sheets, and field journals.
        
    - `/photos` – Original binary photo files (`.jpg`, `.png`, etc.) referenced by the Markdown notes.
        
    - `manifest.json` – Master metadata index describing trip structure, character lists, and timestamps.
        
- File generation completes locally or via background job without choking device resources.
    

### Story S6: Seamless Trip Restoration from Backup (.zip)

**As a** User

**I want to** restore a trip by uploading or selecting a previously exported Plotlines `.zip` backup package

**So that** I can recover a lost trip, import a shared offline trip archive, or migrate trips between devices without errors or missing media.

**Acceptance Criteria:**

- User can select a valid Plotlines `.zip` archive via a "Restore / Import Trip" interface.
    
- System validates the archive's `manifest.json` and file integrity before importing.
    
- Restores all route geometries, segment sequencing, node metadata, cue sheets, Markdown field notes, and photo binaries into the active database/storage.
    
- Validates relative photo paths and internal hyperlinking during sync, resolving media references cleanly without breaking links or throwing schema errors.
    
- Displays a progress bar and completion summary confirming successful import.

### Story S8: Offline & Cloud Sync Status Visual Indicators

**As a** User

**I want to** see explicit visual status badges on trip cards indicating whether a trip is saved locally, synced to the cloud, or fully downloaded for offline use

**So that** I know my trip data is backed up and accessible before going offline or changing devices.

**Acceptance Criteria:**

- Trip cards display distinct status indicators:
    
    - `[Cloud Synced]` – Trip is fully backed up to the remote database.
        
    - `[This Device]` – Local-only trip package (unsynced or guest storage).
        
    - `[Offline Ready]` – All vector basemaps, route geometries, media, and cue sheets are stored locally for off-grid navigation.
        
- Tapping an offline status badge displays total local storage consumed (e.g., _"142 MB downloaded"_).
    

### Story C19: Outdoor High-Contrast Display & Ergonomic Map Controls

**As a** Character navigating outdoors

**I want to** toggle a High-Contrast Outdoor display mode and access primary map controls within the lower-screen thumb zone

**So that** I can read maps in direct sunlight and operate the app one-handed while riding, hiking, or paddling.

**Acceptance Criteria:**

- Map view includes a quick toggle for "Outdoor High-Contrast Mode" featuring max-contrast vector lines, bold topography, and glare-resistant background styling.
    
- Primary interactive controls (re-center map, view cue sheet, toggle layers, emergency info) are positioned within the bottom 40% of the mobile viewport for one-handed thumb reach.
    

### Story C20: Dead-Zone Odometer Mode for GPS Signal Loss

**As a** Character who loses GPS signal in dense cover, deep canyons, or dead zones

**I want the** mobile app to hold my last known map position, alert me gracefully, and switch to a manual odometer/mileage cue reader

**So that** I can continue tracking my position against route markers and cue distances without app failure.

**Acceptance Criteria:**

- When GPS fix is lost, the app alerts the user without freezing or blocking the map interface.
    
- The cue sheet UI switches to "Manual Odometer Mode," allowing the character to step through cue points by manual distance scrolling or milestone taps.
    
- GPS positioning resumes automatically and re-aligns to the active route line once satellite acquisition is re-established.
    

## The Trip Library Stories

### Story 37: Author Trip Library & Portfolio Workspace

**As an** Author

**I want to** access a dedicated Author Trip Library workspace to manage, search, filter, and organize all my planned and drafted adventures

**So that** I can quickly locate existing trips, manage active variants, track participant rosters, and launch new trip builds.

**Acceptance Criteria:**

- Provides a grid/list view of all authored trips, displaying key card details: route thumbnail preview, trip title, primary travel modes, total distance/elevation, day count, variant count, target group size, and sync status badge (`[Cloud Synced]`, `[This Device]`).
    
- Author can filter trips by travel mode (e.g., _Gravel Cycling_, _Multimodal_, _Paddle Trip_), duration (single-day vs. multi-day), or search by trip title/location keyword.
    
- Card action menu provides quick links to: _Edit Route_, _Manage Roster & Preferences_, _Export Backup (.zip)_, and _Clone Trip_.
    

### Story C21: Character Trip Library & Travel Vault

**As a** Character

**I want to** access a personalized Character Trip Library to view all upcoming, active, and completed adventures I have been invited to or participated in

**So that** I can manage my offline downloads, access my daily cue sheets, export routes to my devices, and review past journey recaps.

**Acceptance Criteria:**

- Displays all joined trips categorized under three tabs/sections: **Active / Upcoming**, **Offline Ready**, and **Completed / Archived**.
    
- Each trip card shows trip title, Author name, my individual attendance dates (full trip vs. partial attendance), primary travel modes, and offline download status badge (`[Offline Ready]`).
    
- Character can initiate a single-tap "Download for Offline Use" or "Export to Device (GPX/FIT/TCX)" directly from the trip card menu.
    
- Completed trips link directly to the character's post-trip summary, photo logs, and personal journal entries.






## Backlog - OUT OF SCOPE 
Character Profiler
- upload FIT files that are representative of the characters preferred days

### Story C16: Real-Time Group Location & Rally Status (When Connected)

**As a** Character in a multi-person group

**I want to** view the last-known locations of fellow group members on the map when mesh radio or cellular signal is present

**So that** we can monitor group spread and coordinate regrouping.

**Acceptance Criteria:**

- Map displays avatars/indicators for fellow characters showing their last updated position and time stamp.
    
- Highlights characters who have reached designated Regroup Points or Rest Stops.

### Story C15: Live Offline Navigation & Location Tracking

**As a** Character on the trail or water

**I want to** view my real-time GPS location relative to the active route, off-route threshold alerts, and upcoming cue turns

**So that** I stay on course without draining battery life unnecessarily.

**Acceptance Criteria:**

- Displays real-time location on vector topographic maps without cellular signal.
    
- Displays distance-to-next-cue, distance-to-next-regroup-point, and remaining daily elevation gain.
    
- Configurable off-route alerts warn the user when they wander beyond a designated distance from the planned line.

### Story C11: View Hazard & Technical Crux Alerts _(Counterpart to Author Story 27)_

**As a** Character

**I want to** receive prominent visual alerts and push notifications when approaching Author-designated hazards or technical crux sections

**So that** I am warned of rough access roads, exposed scrambles, or Class IV rapids well in advance.

**Acceptance Criteria:**

- Hazard markers display severity badges (Caution, High Hazard, Mandatory Re-route) and mandatory gear notes.
    
- Mobile app triggers a warning tone or alert header when the user’s offline position approaches within a set distance of a high-severity hazard.

