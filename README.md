## CoughDrop - Every Voice Should Be Heard
[![OpenAAC](https://www.openaac.org/images//OpenAAC-advocate-blue.svg)](https://www.openaac.org/advocates.html)

CoughDrop is an open, web-based AAC (Augmentative and Alternative Communication) app. Basically
if people struggle getting their words out for whatever reason, they can use
the speech synthesis engine on a computing device to "speak" for them. Sometimes
they'll just type on a keyboard (think Stephen Hawking), but sometimes typing is too slow
or not a reasonable expectation, so communication
"boards", which are just grids of labeled pictures, can also be used. CoughDrop supports
building these grids and keyboards, optionally tracks their usage, and also offers
tools for the team supporting the communicator.

CoughDrop is web-based, and will run on most modern browsers. You can try it out
for free at https://www.mycoughdrop.com. It leverages modern web standards like the
Web Speech API, the Application Cache, IndexedDB and a bunch of HTML5 to work
both online and offline. It should run on Windows, Mac, ChromeOS, iOS and Android, and can
be packaged up for app stores as well.

Unlike most other AAC apps, which are installed and live on a single device, CoughDrop
is cloud-based, and syncs edits across multiple devices automatically. This may seem 
unimportant, but when you spend a lot of time building a very personalized vocabulary,
you don't want a broken device or a dead battery to prevent you from communicating. With
CoughDrop you can just log into a different device and keep going.

Additionally, CoughDrop allows users to add "supervisors", which are administrative
users that can help modify boards, track usage reports, and coordinate strategy. In the
past users would have to hand over their device so therapists or parents could make
changes or review usage logs, but with CoughDrop supervisors can do their thing on their
own devices. And permission controls always stay in the hands of the user.

Anyway, that's CoughDrop in a nutshell. There's a lot of extra fun added in, with
built-in assessment and profiling tools, real-time following and remote modeling,
embedded books and videos, two way SMS messaging, modeling ideas and trend reporting,
focus words mode, goal setting and automated tracking, team coordination, 
organizational branding and management tools, classroom-level targets and 
goal tracking, continuing education linking and tracking, etc.
The code is open source so you're free to
run it yourself. We require a code contributor agreement before accepting changes into
our repo. Boards created in CoughDrop use the Open Board Format (http://www.openboardformat.org)
so they should export/import across instances of CoughDrop and a few other systems
without having to dig around in the database.

### Technical Notes

CoughDrop has a Rails backend (`/`) and an Ember frontend (`/app/frontend`), which are 
both contained in this
repository. If you're familiar with those frameworks then hopefully nothing here will
embarrass me too much -- ...I mean, hopefully you'll be able to pick up pretty quickly
the basic makeup of the app. These notes are not comprehensive, Feel free to help
me flesh them out if that's your thing.

The frontend and backend communicate via the open and completely-undocumented API (sorry).
By only using the open API, the mobile apps can easily maintain feature parity 
(and shared codebase) with the web version.

#### Development Considerations

CoughDrop supports multiple locales, so when developing anything on the frontend, whether
in templates or modals and alerts, you will need to use the internationalization libraries
in order to support locales. Do net ever add raw text strings to any user-facing 
resources, always use the i18n helpers. You can find examples of the helpers 
throughout the code, using
commands such as `i18n.t('key', "string")` or `{{t "this is some test" key='key'}}`. Instructions for generating and processing string files is located in `/i18n_generator.rb`.
NOTE: as a standardized convention for the codebase, all user-facing strings should use
double-quotes and all other strings should use single quotes.

#### Backend Setup

Dev dependencies: ruby, Postgres, Redis, Node, ember-cli, AWS, Google API, (optionally) ZenDesk

The backend relies on Redis and Postgres both being installed. Both are required in 
development and production. If 
you have ruby installed in your environment, you'll need the bundler gem:

```
gem install bundler
```

After that you can install ruby dependencies with:

```
bundle install
```

Next, you'll need to set some environment variables. The easiest way to do this
is with a `.env` file:

```
cp .env.example .env
```

You'll need to uncomment (remove the "# " at the beinning of) 
the first group of variables since they're required. For the `REDIS_URL` line,
enter a valid redis url (default would be `REDIS_URL=redis://localhost:6379/`). 
Then update
`config/database.yml` to match your settings (the defaults may work fine) if you
setup a vanilla postgres instance.

<i>Redis quickstart: https://redis.io/topics/quickstart</i>

Next you'll want to setup your database. Before you can do that, you'll need to address
a couple of dangling symbolic links, but we have a command to help with that. 
Here's the sequence that should work:

```
rails extras:assert_js
rails db:create
rails db:migrate
rails db:seed
```

You can skip the last command if you want, it'll populate with some bootstrap data including
a login, `example` and `password` to get you started.

Once the database is created, you can start the server. If you run `rails server` you
can start a single server process and hit it up in your browser at the default address
(`http://localhost:3000` or whatever you changed it to). You'll be stuck on the
loading page because the frontend hasn't compiled the frontend javascript yet.

#### Frontend Setup

The frontend is an ember app. I recommend installing ember-cli (https://ember-cli.com/user-guide/)
to make your life easier. Once you've got ember-cli installed, run:

```
cd app/frontend
npm install
bower install
ember serve
```


To download all the app dependencies at once. It'll ask you about modifying files, 
if you're not sure what to do enter "n" if it asks about replacing a file. Otherwise
you can check the diffs and see what you'd like to keep/change.

Once you have the dependencies downloaded, then any code changes within `frontend` should
automatically regenerate `frontend.js` which is what the Rails app makes sure to deliver
to the browser.

#### Running the Full System
CoughDrop has more than one process needed for things to run correctly. You can look in 
`Procfile` for the commands we use to run a web server or a resque (background job) server.
The ember process is for development. It auto-compiles code as it's written, and shouldn't
be run in production. The easiest way to get things up and running is with the foreman gem:

```
gem install foreman
foreman start
```

or if you have heroku-cli installed:

```
heroku local
```

That'll run one instance of each process in the Procfile, which is more than you need
but it'll work. After you start the ember process, it'll probably take around a minute or so for
it to compile the javascript for the first time. You should see some notes on the console
about a successful build, then you can reload your browser and see the welcome page. You
should be able to log in and go to town.

To deploy the app, you'll want to precompile all assets. The easiest way to do this is to run `bin/deploy_prep`. To prep mobile and desktop app releases you can run `rake extras:mobile`
and `rake extras:desktop` to push the latest code to those directories, assuming they
are available on your dev system.

##### Additional Dependencies

In order to support generating utterances for sharing,  downloading pdfs, and uploading
images, you'll need to have
ImageMagick (`convert`, `identify`, `montage`), ghostscript (`gs`), and Node (`node`) 
installed in the execution path. There are also a number of server-side integrations you
can install that require secure keys, they are listed in `.env.example` with explanations
of where they are required. Note that if you're trying to run a production environment, 
not all functionality will degrade gracefully without these environment variables.

If using Postgres.app on a Mac, you'll want to open the config for the
db and increase max_connections to, say, 999

There are also some rake tasks you'll want to schedule to run periodically. I use 
Heroku Scheduler to run them at the specified frequency:

```
rake check_for_expiring_subscriptions (run daily)
rake generate_log_summaries (run hourly)
rake push_remote_logs (run hourly)
rake check_for_log_mergers (run hourly)
rake advance_goals (run hourly)
rake transcode_errored_records (run daily)
rake flush_users (run daily)
rake clean_old_deleted_boards (run daily)
```

CoughDrop also utilizes a separate site that it uses for web sockets to track
online status and support real-time interactions. Additionally, CoughDrop relies on access
to an opensymbols.org-type endpoint for image search. Also there are multiple AWS and Google
API endpoints that can and probably should be enabled. Google API is straightforward, just
needs an access token for Places, Translate, Maps, & TTS. AWS is a little more complicated,
you can implement access keys for SES (emails), SNS (notifications, potentially two-way so see api/callbacks_controller), S3 storage (probably required
at this point), Elastic Transcoder (need pipelines for converting audio & video to standardized formats, also need to configure pipeline callbacks -- see api/callbacks_controller). Additional less-vital integrations are listed in .env.example

When developing code for CoughDrop, make sure to take into consideration that the
codebase is deployed both as a web app, and as a packaged app on mobile and desktop apps.
All platform-specific code should be extracted from the codebase or encapsulated within
the `capabilities` library when necessary. Capabilities checks may be used to 
enable features only when their associated capabilities are available.

On a related front, new features should be added first behind a Feature Flag (`lib/feature_flags.rb`), especially if it will affect any interactions for the end-user.
Some AAC users can find it difficult when things change unexpectedly (even something
as innocuous as an icon or color change can be disruptive), so new features and interfaces
should be held behind a Feature Flag, and released once a change management strategy 
is sufficiently implemented. We also use Feature Flags to hold back beta features and
interfaces until they have had time to be fully tested. Keep in mind that some users 
are opted in to access to all beta features, to allow organizations proper time to
test on their own as well.

##### Translations

See `i18n_generator.rb' for scripts to manage translation files. In controller code,
use the `i18n` library for any user-facing strings, and in templates use the 
`{{t }}` template helper for translations. The convention throughout the codebase
should ALWAYS remain double-quotes for user-face strings, single-quotes for everything 
else. The generator libraries depend on this consistency, and it helps significantly
when searching the codebase.

Additionally, the admin organization has a special importing tool, "Word Data Import" 
that can be used to import data from multiple locales. This data is used when buttons
are created or modified, to automatically colorize by parts of speech, and to 
generate inflections for buttons, contractions, and for auto-inflection preferences
(i.e. when a user hits "I want" and then "eat" automatically changes to "to eat").
There are two separate file types, rules.json and words.json, which both have templates
available at [https://tools.openaac.org/inflections/inflections.html](OpenAAC).

##### Troubleshooting

Need console access? Normally on Heroku you would just run 'heroku run rails console' to 
get production access, or just 'rails console' for a local Ruby console. Since CoughDrop
needs to ensure user data remains protected, all production requests need to be audited
(see the model `AuditEvent`), so there are some safeguards to prevent unaudited 
console access, and you'll need to run `bin/heroku_console` to get yourself a production
console prompt. Many of the following examples assume they are being run from a console prompt.

```
b = Board.find_by_path('example/keyboard)
downs = Board.find_all_by_global_id(b.downstream_board_ids)
u = User.find_by_path('username')
u.global_id
u.settings['preferences']['home_board]
s = u.log_sessions.last
s.data['events']
bi = ButtonImage.last
bi.url
```

Redis memory too full? `RedisInit.size_check` also `rake extras:clear_report_tallies`

Job queues backed up? `Worker.method_stats(queue_name)`

Want to remove all instances of a method from the background? `Worker.prune_jobs(queue_name, method_name)`

See also CODE_INVESTIGATION.md

### Contribution Ideas

CoughDrop is an actively-developed system with an API-driven Rails backend and
a rather heavy Ember frontend. This can be intimidating, even for people
who know these frameworks, and prevent people from contributing. If you 
would like to contribute, you can join the (https://www.openaac.org)[OpenAAC Slack Channel]
and ask for ideas or pointers. In addition, here are some fairly modular
components that I haven't had time to develop, and would love a contribution
on:

- Dynamic Scene Displays framework to build photo-based interfaces for activating objects on a scene (consider using (https://github.com/CoughDrop/aac_shim)[aac_shim]
- External API Integrations (recent news, movie tickets, etc.) (consider using (https://github.com/CoughDrop/aac_shim)[aac_shim]
- Core word service to return information on a word including most common part of speech, common variations/tenses, etc.
- Make mobile/desktop apps able to download the latest version of the javascript code, so 
the apps can be updated dynamically when all that's changed is the scripts
- API documentation (yeah I know, I should have done it along the way)
- Maintenance Work:
- Upgrade Rails & Ruby (and ensure everything still works, then bump to latest Heroku stack)
  - For CoughDrop, CoughDrop-Websocket, presenters.aacconference.com
- Upgrade Cordova (and ensure everything still works)
- Upgrade Electron (and re-build dependencies for new version)
  - Generate a new signing cert or move to Microsoft app store for updates
- Upgrade Ember (avoided this for a long time because it kept having breaking changes)
- Remove cache manifests and update offline support for mobile
- Add support for iOS Personalized Voices (should be easy)

I'm happy to provide guidance for any of these projects to help get them underway :-).

### License

Copyright (C) 2014-2019 CoughDrop, Inc.

Released under the AGPLv3 license or later.
