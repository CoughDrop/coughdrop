## CoughDrop - Code Investigation

CoughDrop is a large repository at this point, with a lot of moving parts. 
Ideally there wouldn't be areas of code that commonly come up when
troubleshooting/bug fixing, but I'm just not that good of a coder, sorry.

### Frontend

Most of the frontend code consists of Ember files, `controllers` and `templates`
which should be relatively straightforward even if you're not an Ember pro.
There are some UI `components` used for generating graphs, charts, and other
pieces of data or embeds. In general the non-UI-related code is housed in the
`utils` folder, with the following utility files found there:

__stashes__ - abstraction layer for persisting basic data to localStorage. Things stored
in the stash should be considered non-essential as it's possibly they will be erased
without notification, but can be used for session-related preferences. Also used to
store user log data until it can be persisted to the server.

__app_state__ - handles application state, including may event handlers related to state.

__board_hierarchy__ - used to render all the sub-boards of a current board.

__bound_classes__ - generates css classes based on the styling of different boards, to 
prevent polluting the page with enormous element-based style rules.

__button__ - buttons are not persisted to the server, they are stored on a board
object, but there are many helper methods that make working with and rendering buttons
easier.

__capabilities__ - any system-level calls should be contained in capabilities.js or 
one of its sub-libraries. Everything from file storage to gaze tracking to copy 
and paste.

__content_grabbers__ - tools for searching and adding images, sounds, and videos
to buttons or other parts of the interface.

__dbman__ - a sub-library of capabilities. this is an abstraction layer for sqlite 
or indexed-db depending on the system.

__edit_manager__ - store state related to editing including unde/redo states, also
responsible for generating renderable or saveable versions of board data.

__eval__ - evals are a special type of `obf` that test and track how well a user
can find and hit buttons.

__extras__ - extras houses an ajax override, as well as some related resources 
related to headers that are send on all API requests.

__frame_listener__ - aac_shim utility library.

__geo__ - basic helper library for geolocation-related features.

__i18n__ - houses all internationalization helpers and utilities, as well
as some basic English-related grammar rules and helpers.

__misc__ - a few helper functions that don't fit elsewhere, for waiting on 
all promises to resolve, retrieving all pages of an paginated API result.

__modal__ - tools for popping up modals and flash notices in the UI. NOTE:
newed modals are housed in sub-folders `controllers/modals` and 
`templates/modals` but some of the other modals have not been moved there yet.

__obf-emergency__ - obf sub-library for special boards that should always
be available, even without a sync.

__obf__ - obf-related library for rendering custom types of interfaces.

__persistence__ - abstraction layer for any local database-related tools,
as well as overrides for Ember-Data caching purposes.

__profiles__ - tool for running surveys and assessments.

__progress_tracker__ - helper library for tracking API calls that return 
a progress result.

__raw_events__ - low-level DOM-related listeners for clicks, drags, dwell
events, etc. Most of the eye-gaze-related resources are housed here.

__scanner__ - all the scanning-related code other than a few low-level 
listeners are housed here.

__session__ - session authentication and storage helpers.

__speecher__ - speech-generating resources.

__stats__ - helpers for retrieving user usage reports.

__subscription__ - helpers for managing user subscriptions.

__sync__ - tracking online status of, and initiating remote modeling
sessions.

__tts_voices__ - all the commercial TTS presets.

__utterance__ - tracking and processing the contents of the sentence box
for rendering, sharing, etc.

#### Models

Most client-side model names match the server-side corollary, but
not all. They all should be easy to find even if the names don't match.
Most of the models only have some basic helpers that should be
relatively straightforward, but `User`, `Board` and `ButtonSet` models 
are relatively large, just because of all the available functionality.

#### Gotchas

`editManager.process_for_displaying` - This code takes the data
given from the server and converts it into a renderable format, so 
if boards ever stop rendering this is where to start.

`Board.contextualized_buttons` - If boards start showing the wrong
languages or symbols in Speak Mode, or don't update to show the
correct inflections, this is a good place to start looking.

`persistence.getJSON` - This code may have issues processing
the encrypted results sent as URLs by extra_data objects.

`persistence.sync` - If users cannot sync or their syncs do not
actually save data correctly for offline use, this is where to start.

`CoughDrop.Board.skinned_url` - If boards show the original symbols
instead of the user-preferred symbol library or skin tone, there may
be an issue here.

`initializes/attempt_lang.js` - When the app first starts up, this
code will try to load the correct language files, so if the interface
isn't showing in the correct language, there may be something wrong here.

`app_state.activate_button` - This is the main section of code that 
handles button selection. When a user hits or selects a button by
any means, this code decides what to do with it, including how to
add it to the sentence box, how to speak it, how to perform extra
actions, etc.

`controllers/board/index.js:computeHeight` - If boards aren't rendering
with the correct size of buttons or filling the space correctly, check
here.

`CoughDrop.Buttonset.load_button_set` - This code occasionally has problems.
There may be a caching issue somewhere. When users want to load a button set
the logic is executed here to try to load the button set if the user is online,
or use the cached version if the user is offline. If the user is online and they
have a cached version, it can still try to download over an outdated version.

`ButtonSet.find_buttons` - Find-a-button feature runs from here.

`User.currently_premium` - The logic here is not as straightforward as I 
would like, but this check is used to decide whether users can see
*all* features of CoughDrop, or only a limited set. When users pay a
one-time fee or when they cancel their subscription, they can still use the
app, but they won't have access to all of the "cloud extras" features.

`User.copy_home_board` - Used by the setup wizard and other places to
set the user's new home board. This should run and return relatively
quickly even for large board sets, or else users will get bothered by
the slowness of setting up their initial account settings.

`editManager.copy_board` - If users are having issues copying a whole
board set, for example if they say not all the boards got updated to their
new copy, or some still point to the old copy, you may need to make changes
here. Especially if they say that after a few hours it seems to fix
itself, then it's possible the issue is a UI issue only, not a server problem.

### Backend

This is a standard Rails app, with a few exceptions. Very little Rails frontend
support is utilized, as we mostly use it to bootstrap Ember views. The web
app, as well as all the mobile apps, communicate via the same API for consistency.

To allow for future sharding, I don't use raw database IDs in my apps. CoughDrop
implements a `global_id` attribute which future-proofed for sharding if it
ever came up. We ended up using for some other helpers along the way, but the
basic format for IDs in CoughDrop is "#shardnum#_#dbid#".

JSON generation for the API is all housed in `lib/json_api` rather than
using the standard Rails JSON generators.

Session-related methods (include SAML and OAuth) are found in `session_controller.rb`

Mailers use the `mailer_helper.rb` because it was easier to get implemented than
with the standard Rails process.

#### Model-Related Helpers (Concerns)

__async__ - helpers for scheduling background jobs.

__board_caching__ - tracking the list of ids available for a user from a given board.

__extra_data__ - helpers for storing large data sets 
(LogSession and BoardDownstreamButtonSet records) on S3 rather than in the DB.

__global_id__ - helpers for CoughDrop's id lookups. Did this to allow for sharding more
easily in the future. The most common methods are `find_by_global_id` (looks up
only by id) and `find_by_path` (looks up by id, or board key or user name, depending).
Additionally, some records have protected ids, which means they can only be looked 
up by id-and-nonce to prevent snooping. See also `find_all_by_global_id`
and `find_batches_by_global_id`.

__media_object__ - helpers for transcoding stored media objects.

__meta_record__ - data sent in HTML headers for specific record landing pages.

__notifiable__ - helpers for record types that can receive internal notifications.
These could be triggered by a board being updated, a user receivinga a message,
etc.

__notifier__ - helpers for record types that can send internal notifications.

__passwords__ - password-related helpers.

__permissions__ - looking up and setting access permissions for records. Models
use the `add_permissions` method, controllers can called `allowed?`, etc.

__processable__ - helpers for processing client-side data in a standardized way.
Also helps enforce uniqueness keys when needed.

__relinking__ - helpers for copying whole board sets server-side.

__renaming__ - boards are sometimes renamed (specifically re-keyed).

__replicate__ - models that can be looked up on the follower database.

__secure_serialize__ - privacy regulations require additional protections on 
sensitive data, so we add an encryption layer to all potentially-sensitive 
database records.

__sharing__ - helpers for sharing boards with other users.

__subscription__ - managing subscription/purchase-related events.

__supervising__ - helpers for managing supervisors.

__uploadable__ - button images and sounds can be uploaded by the end-user 
directly using permission tokens, these are some helper methods.

__upstream_downstream__ - keeps everything up-to-date when a downstream board
is modified.

#### Libraries

__converters/__ - used for exporting content to obf/obz files.

__json_api/__ - generates JSON records that are sent slient-side.

__admin_constraint__ - helps enforce only admins getting access to background jobs list.

__app_searcher__ -  not used hardly ever, allows searching for apps.

__arpa_to_json__ - converts ngrams to a json file for keyboard suggestions.

__board_merger__ - never implemented.

__exporter__ - exports data to standardized formats like obf and obl, including
anonymization support.

__external_tracker__ - syncs user data with HubSpot.

__feature_flags__ - used to check whether users have access to specific features.
Also tracks which features are still behind a feature flag.

__flusher__ - helpers for completely deleting a user from the system.

__geolocation__ - geolocation-related helpers, including generating common
locations where logs are generated.

__moby_parser__ - parses moby file for word frequencies.

__purchasing__ - handles Stripe-related API calls.

__pusher__ - SMS messaging handler.

__renamer__ - helpers for renaming boards.

__sentence_pic__ - helper for generating image preview of a sentence shared via utterance record.

__slow_worker__ - slow version of Worker.rb, uses a different queue.

__stats__ - ingests sets of log data and outputs different summaries and reports. See also
`WeeklyStatsSummary`.

__tiny_color_convert.js__ - used server-side to match tinycolor use client-side.

__transcoder__ - handles inbound AWS transcoding events.

__uploader__ - helpers for uploading files both client-side and server-side.

__worker__ - handles background job-related events and tracking, as well as
a few troubleshooting methods for in case queues get too huge.

#### Gotchas

`boards_contoller#index` - Lots of code needed here for searching across all
available boards. Can be a performance bottleneck, because it requires
indexes on the boards table as well as board_locales, and needs to be able
to search through private boards which aren't search indexed.

`BoardDownstreamButtonSet.update_for` - Updates a button set. Button sets
are used by find-a-button, copying boards, or showing the board hierarchy
in the UI. Button sets contain all buttons on the linked board and all of its
sub-boards, so the list can get quite large, and potentially needs to be
updated very often when a user is working on multiple boards in their 
account.

`models/concerns/relinking.rb` - If users start complaining that when they
copy a board set only the top board gets copied, or not all of the sub-boards
get copies, then this is the place to look.

`models/concerns/extra_data.rb` - This code is used to store large
data in S3 instead of in the database to keep the db size down, but
if users start reporting that they can't load button sets, it may
have to do with the caching set up here.

`BoardContent` - When users make copies of boards, we copy by reference
wherever possible to keep size down. If users make copies and then
can't edit the copies or have mismatched data, this is a good
place to look.

`Board.process_buttons` - This is most of the backend processing for
updating a board.

`models/concerns/upstream_downstream.rb#track_downstream_boards!` - The
code here will get run often, so if it ever gets slow you will definitely
see the background queues get backed up. There can be other reasons
for queue jams, but this is a likely culprit.

`Purchasing.purchase` - If Stripe purchases stop working or users
report issues activating their subscriptions, this is the place to start
looking.