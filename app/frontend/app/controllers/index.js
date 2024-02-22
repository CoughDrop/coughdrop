import Ember from "ember";
import Controller from "@ember/controller";
import EmberObject from "@ember/object";
import { set as emberSet, get as emberGet } from "@ember/object";
import { later as runLater } from "@ember/runloop";
import $ from "jquery";
import CoughDrop from "../app";
import persistence from "../utils/persistence";
import capabilities from "../utils/capabilities";
import app_state from "../utils/app_state";
import Badge from "../models/badge";
import session from "../utils/session";
import modal from "../utils/modal";
import sync from "../utils/sync";
import stashes from "../utils/_stashes";
import i18n from "../utils/i18n";
import { htmlSafe } from "@ember/string";
import { observer } from "@ember/object";
import { computed } from "@ember/object";

export default Controller.extend({
  queryParams: ["redirect_to_modern_view"],
  registration_types: CoughDrop.registrationTypes,
  sync_able: computed(
    "extras.ready",
    "app_state.currentUser.external_device",
    function () {
      return (
        this.get("extras.ready") &&
        !app_state.get("currentUser.external_device")
      );
    }
  ),
  home_board_or_supporter: computed(
    "app_state.currentUser.preferences.home_board.key",
    "app_state.currentUser.supporter_view",
    function () {
      return (
        this.get("app_state.currentUser.preferences.home_board.key") ||
        this.get("app_state.currentUser.supporter_view")
      );
    }
  ),
  needs_sync: computed("persistence.last_sync_at", function () {
    var now = new Date().getTime() / 1000;
    return now - persistence.get("last_sync_at") > 7 * 24 * 60 * 60;
  }),
  triedToSave: false,
  badEmail: computed("user.email", "triedToSave", function () {
    var email = this.get("user.email");
    return this.get("triedToSave") && !email;
  }),
  shortPassword: computed("user.password", "triedToSave", function () {
    var password = this.get("user.password") || "";
    return this.get("triedToSave") && password.length < 6;
  }),
  noName: computed("user.name", "user.user_name", "triedToSave", function () {
    var name = this.get("user.name");
    var user_name = this.get("user.user_name");
    return this.get("triedToSave") && !name && !user_name;
  }),
  noSpacesName: computed("user.user_name", function () {
    return !!(this.get("user.user_name") || "").match(/[\s\.'"]/);
  }),
  blank_slate: computed(
    "app_state.currentUser.preferences.progress",
    "app_state.currentUser.using_for_a_while",
    function () {
      var progress = this.get("app_state.currentUser.preferences.progress");
      // TODO: eventually this should go away, maybe after a few weeks of active use or something
      if (progress && progress.setup_done) {
        return null;
      } else if (this.get("app_state.currentUser.using_for_a_while")) {
        return null;
      } else {
        return progress;
      }
    }
  ),
  no_intro: computed(
    "blank_slate",
    "app_state.currentUser.preferences.progress.intro_watched",
    function () {
      return (
        this.get("blank_slate") &&
        !this.get("app_state.currentUser.preferences.progress.intro_watched")
      );
    }
  ),
  blank_slate_percent: computed(
    "app_state.currentUser.preferences.progress",
    function () {
      var options = [
        "intro_watched",
        "profile_edited",
        "preferences_edited",
        "home_board_set",
        "app_added",
      ];

      var total = options.length;
      if (total === 0) {
        return 0;
      }
      var done = 0;
      var progress =
        this.get("app_state.currentUser.preferences.progress") || {};
      if (progress.setup_done) {
        return 100;
      }
      options.forEach(function (opt) {
        if (progress[opt]) {
          done++;
        }
      });
      return Math.round((done / total) * 100);
    }
  ),
  blank_slate_percent_style: computed("blank_slate_percent", function () {
    return htmlSafe("width: " + this.get("blank_slate_percent") + "%;");
  }),
  checkForBlankSlate: observer("persistence.online", function () {
    var _this = this;
    if (Ember.testing) {
      return;
    }
    persistence.find_recent("board").then(
      function (boards) {
        if (boards && boards.slice) {
          boards = boards.slice(0, 12);
        }
        _this.set("recentOfflineBoards", boards);
        if (_this.get("homeBoards") == [] && _this.get("popularBoards") == []) {
          _this.set("showOffline", true);
        } else if (!_this.get("persistence.online")) {
          _this.set("showOffline", true);
        } else {
          _this.set("showOffline", false);
        }
      },
      function () {
        _this.set("showOffline", false);
      }
    );
  }),
  device: computed(function () {
    var res = {
      added_somewhere: !!this.get(
        "app_state.currentUser.preferences.progress.app_added"
      ),
      standalone: capabilities.browserless,
      android: capabilities.system == "Android",
      ios: capabilities.system == "iOS",
    };

    res.needs_install_reminder =
      !res.added_somewhere || ((res.android || res.ios) && !res.standalone);
    if (res.standalone && (res.android || res.ios)) {
      res.needs_install_reminder = false;
    } else if (this.get("app_state.currentUser.using_for_a_while")) {
      res.needs_install_reminder = false;
    }
    return res;
  }),
  small_needs_sync_class: computed("needs_sync", function () {
    var res = "half_size list-group-item ";
    if (!this.get("needs_sync")) {
      res = res + "subtle ";
    }
    return res;
  }),
  refreshing_class: computed("persistence.syncing", function () {
    var res = "glyphicon glyphicon-refresh ";
    if (this.get("persistence.syncing")) {
      res = res + "spinning ";
    }
    return res;
  }),
  needs_sync_class: computed("needs_sync", function () {
    var res = "list-group-item ";
    if (!this.get("needs_sync")) {
      res = res + "subtle ";
    }
    return res;
  }),
  current_boards: computed(
    "popular_selected",
    "personal_selected",
    "suggested_selected",
    "recent_selected",
    "popularBoards",
    "personalBoards",
    "homeBoards",
    "recentOfflineBoards",
    function () {
      var res = {};
      if (this.get("popular_selected")) {
        res = this.get("popularBoards");
      } else if (this.get("personal_selected")) {
        res = this.get("personalBoards");
      } else if (this.get("suggested_selected")) {
        // filter out boards that have a style.id but not style.name
        res = this.get("homeBoards");
        if (res.filter) {
          var ids = {};
          res.forEach(function (b) {
            if (b.get("style.options")) {
              ids[b.get("style.id")] = true;
            }
          });
          res = res
            .filter(function (b) {
              return (
                !b.get("style") ||
                !ids[b.get("style.id")] ||
                b.get("style.options")
              );
            })
            .slice(0, 12);
        }
      } else if (this.get("recent_selected")) {
        res = this.get("recentOfflineBoards");
      }
      return res;
    }
  ),
  pending_updates: computed(
    "app_state.currentUser.pending_org",
    "app_state.currentUser.pending_supervision_org",
    "app_state.currentUser.pending_board_shares",
    "app_state.currentUser.unread_messages",
    function () {
      var important =
        this.get("app_state.currentUser.pending_org") ||
        this.get("app_state.currentUser.pending_supervision_org") ||
        (this.get("app_state.currentUser.pending_board_shares") || []).length >
          0 ||
        this.get("app_state.currentUser.unread_messages");
      var normal_new = app_state.get("currentUser.unread_messages.length") || 0;
      var unread_notifications = (
        app_state.get("currentUser.parsed_notifications") || []
      ).filter(function (n) {
        return n.unread;
      }).length;
      normal_new = normal_new + (unread_notifications || 0);

      if (normal_new && !app_state.get("currentUser.read_notifications")) {
        return { count: normal_new };
      } else if (important) {
        return true;
      } else {
        return null;
      }
    }
  ),
  update_selected: observer("selected", "persistence.online", function () {
    var _this = this;
    if (!persistence.get("online")) {
      return;
    }
    var last_browse = stashes.get("last_index_browse");
    var default_index = 2;
    // If a user already has a home board they're not going to care about popular boards,
    // they want to see something more useful like all the boards they own, or maybe
    // the home boards of all their supervisees, or maybe all their starred boards
    if (app_state.get("currentUser.preferences.home_board.key")) {
      if (app_state.get("currentUser.stats.user_boards") > 0) {
        default_index = 1;
      } else {
        default_index = 3;
      }
    }
    ["popular", "personal", "suggested", "recent"].forEach(function (key, idx) {
      if (
        _this.get("selected") == key ||
        (!_this.get("selected") && idx === default_index && !last_browse) ||
        (!_this.get("selected") && last_browse == key)
      ) {
        _this.set(key + "_selected", true);
        if (_this.get("selected")) {
          stashes.persist("last_index_browse", key);
        }
        if (key == "recent") {
          persistence.find_recent("board").then(function (boards) {
            if (boards && boards.slice) {
              boards = boards.slice(0, 12);
            }
            _this.set("recentOfflineBoards", boards);
          });
        } else {
          var list = "homeBoards";
          var locale = (
            (i18n.langs || {}).preferred ||
            window.navigator.language ||
            "en"
          ).split(/-/)[0];
          if (app_state.get("currentUser.preferences.locale")) {
            locale = app_state
              .get("currentUser.preferences.locale")
              .split(/-/)[0];
          }
          var opts = {
            public: true,
            starred: true,
            user_id: app_state.get("domain_board_user_name"),
            sort: "custom_order",
            per_page: 20,
            preferred_locale: locale,
          };
          if (key == "personal") {
            list = "personalBoards";
            opts = { user_id: "self", root: true, per_page: 12 };
          } else if (key == "popular") {
            list = "popularBoards";
            opts = {
              sort: "home_popularity",
              per_page: 12,
              exclude_starred: app_state.get("domain_board_user_name"),
              locale: locale,
            };
          }
          if (!(_this.get(list) || {}).length) {
            _this.set(list, { loading: true });
          }
          _this.store.query("board", opts).then(
            function (data) {
              _this.set(list, data);
              _this.checkForBlankSlate();
            },
            function () {
              _this.set(list, { error: true });
            }
          );
          _this.checkForBlankSlate();
        }
      } else {
        _this.set(key + "_selected", false);
      }
    });
  }),
  allow_logs: computed(
    "app_state.currentUser.preferences.logging",
    "app_state.currentUser.modeling_only",
    "app_state.currentUser.supporter_role",
    "session.modeling_session",
    function () {
      return (
        app_state.get("currentUser.preferences.logging") &&
        !app_state.get("currentUser.supporter_role") &&
        !app_state.get("currentUser.modeling_only") &&
        !session.get("modeling_session")
      );
    }
  ),
  reload_logs: observer("model.id", "persistence.online", function () {
    var model = this.get("model");
    var _this = this;
    if (model && model.get("id") && persistence.get("online")) {
      var controller = this;
      var find_args = { user_id: model.get("id"), type: "session" };
      if (model.get("supporter_role")) {
        find_args.supervisees = true;
      }
      if (!(controller.get("logs") || {}).length) {
        controller.set("logs", { loading: true });
      }
      this.store.query("log", find_args).then(
        function (list) {
          controller.set(
            "logs",
            list.map(function (i) {
              return i;
            })
          );
        },
        function () {
          if (!(controller.get("logs") || {}).length) {
            controller.set("logs", { error: true });
          }
        }
      );
      this.store.query("badge", { user_id: model.get("id"), recent: 1 }).then(
        function (badges) {
          var for_users = {};
          badges.forEach(function (badge) {
            for_users[badge.get("user_id")] =
              for_users[badge.get("user_id")] || [];
            for_users[badge.get("user_id")].push(badge);
          });
          _this.set("current_user_badges", for_users);
        },
        function (err) {}
      );
      model.load_word_activities();
    }
  }),
  best_badge: function (badges, goal_id) {
    return Badge.best_next_badge(badges, goal_id);
  },
  earned_badge: function (badges) {
    return Badge.best_earned_badge(badges);
  },
  update_current_badges: observer(
    "app_state.sessionUser",
    "app_state.sessionUser.known_supervisees",
    "session.modeling_session",
    "current_user_badges",
    function () {
      var _this = this;
      var model = _this.get("model");
      var for_users = _this.get("current_user_badges") || {};
      if (model && for_users[model.get("id")]) {
        var b = _this.best_badge(
          for_users[model.get("id")],
          model.get("goal.id")
        );
        var eb = _this.earned_badge(for_users[model.get("id")]);
        if (
          !app_state.get("sessionUser.currently_premium") ||
          app_state.get("sessionUser.supporter_role") ||
          session.get("modeling_session")
        ) {
          b = null;
        }
        // If no badge for the current user use the supervisee if there's only one
        if (
          !b &&
          (app_state.get("sessionUser.known_supervisees") || []).length == 1
        ) {
          var sup = app_state.get("sessionUser.known_supervisees")[0];
          if (sup.premium) {
            b = _this.best_badge(
              for_users[emberGet(sup, "id")],
              (sup.goal || {}).id
            );
          }
        }
        emberSet(model, "current_badge", b);
        emberSet(model, "earned_badge", eb);
      }
      var sups = [];
      (app_state.get("sessionUser.known_supervisees") || []).forEach(function (
        sup
      ) {
        if (for_users[emberGet(sup, "id")] && emberGet(sup, "premium")) {
          var b = _this.best_badge(
            for_users[emberGet(sup, "id")],
            (sup.goal || {}).id
          );
          emberSet(sup, "current_badge", b);
          var eb = _this.earned_badge(for_users[emberGet(sup, "id")]);
          emberSet(sup, "earned_badge", eb);
        }
        if (CoughDrop.remote_url(sup.avatar_url) && !sup.local_avatar_url) {
          persistence.find_url(sup.avatar_url, "image").then(
            function (url) {
              emberSet(sup, "local_avatar_url", url);
            },
            function (err) {}
          );
        } else if (
          sup.local_avatar_url &&
          sup.local_avatar_url.match(/localhost/)
        ) {
          emberSet(
            sup,
            "local_avatar_url",
            capabilities.storage.fix_url(sup.local_avatar_url)
          );
        }
        sups.push(sup);
      });
      _this.set("supervisees_with_badges", sups);
    }
  ),
  modeling_ideas_available: computed(
    "app_state.sessionUser.supporter_role",
    "app_state.sessionUser.currently_premium",
    function () {
      if (app_state.get("sessionUser.currently_premium")) {
        return true;
      } else if (app_state.get("sessionUser.supporter_role")) {
        var any_premium_supervisees = false;
        (app_state.get("sessionUser.known_supervisees") || []).forEach(
          function (sup) {
            if (
              emberGet(sup, "premium") ||
              emberGet(sup, "currently_premium")
            ) {
              any_premium_supervisees = true;
            }
          }
        );
        if (any_premium_supervisees) {
          return true;
        }
      }
      return false;
    }
  ),
  many_supervisees: computed("app_state.currentUser.supervisees", function () {
    return (app_state.get("currentUser.supervisees") || []).length > 5;
  }),
  some_supervisees: computed("app_state.currentUser.supervisees", function () {
    return (app_state.get("currentUser.supervisees") || []).length > 3;
  }),
  save_user_pref_change: observer(
    "app_state.currentUser.preferences.auto_open_speak_mode",
    function () {
      var mode = app_state.get("currentUser.preferences.auto_open_speak_mode");
      if (mode !== undefined) {
        var last_mode = this.get("last_auto_open_speak_mode");
        if (last_mode !== undefined && mode !== null && last_mode != mode) {
          app_state
            .get("currentUser")
            .save()
            .then(null, function () {});
        }
        this.set("last_auto_open_speak_mode", mode);
      }
    }
  ),
  index_nav: computed(
    "index_nav_state",
    "model.supporter_role",
    "app_state.currentUser.preference.device.last_index_nav",
    function () {
      var res = {};
      if (this.get("index_nav_state")) {
        res[this.get("index_nav_state")] = true;
      } else if (
        app_state.get("currentUser.preferences.device.last_index_nav")
      ) {
        res[
          app_state.get("currentUser.preferences.device.last_index_nav")
        ] = true;
      } else {
        if (this.get("model.supporter_role")) {
          //        res.supervisees = true;
          res.main = true;
        } else {
          res.main = true;
        }
      }
      return res;
    }
  ),
  subscription_check: observer(
    "app_state.sessionUser",
    "app_state.logging_in",
    function () {
      // if the user is in the free trial or is really expired, they need the subscription
      // modal to pop up
      if (
        this.get("app_state.sessionUser") &&
        !this.get("app_state.installed_app")
      ) {
        var progress = this.get("app_state.sessionUser.preferences.progress");
        var user = this.get("app_state.sessionUser");
        var needs_subscribe_modal = false;
        if (
          !progress ||
          (!progress.skipped_subscribe_modal && !progress.setup_done)
        ) {
          if (user.get("grace_period")) {
            if (modal.route) {
              needs_subscribe_modal = true;
            }
          }
        } else if (this.get("app_state.sessionUser.really_expired")) {
          needs_subscribe_modal = true;
        }
        if (needs_subscribe_modal && !app_state.get("logging_in")) {
          if (!this.get("app_state.installed_app")) {
            modal.open("subscribe");
          } else {
            // TODO: ...
          }
        }
      }
    }
  ),
  rating_allowed: computed("app_state.sessionUser", function () {
    if (
      capabilities.installed_app &&
      capabilities.mobile &&
      capabilities.subsystem != "Kindle"
    ) {
      // TODO: try to check for engagement
      var progress = app_state.get("sessionUser.preferences.progress") || {};
      if (progress.rated) {
        return false;
      }
      // Wait 4 weeks before inviting to rate
      if (
        app_state.get("sessionUser.joined") &&
        app_state.get("sessionUser.joined") < window.moment().add(-28, "day")
      ) {
        // show prompt a week at a time, every 4 weeks
        return (
          Math.round(
            app_state.get("sessionUser.joined").getTime() /
              1000 /
              60 /
              60 /
              24 /
              7
          ) %
            4 ==
          0
        );
      }
    }
    return false;
  }),
  actions: {
    invalidateSession: function () {
      session.invalidate(true);
    },
    reload: function () {
      location.reload();
    },
    searchBoards: function () {
      this.transitionToRoute("search", "any", encodeURIComponent("_"));
    },
    quick_assessment: function (user) {
      if (emberGet(user, "premium") || emberGet(user, "currently_premium")) {
        var _this = this;
        modal.open("quick-assessment", { user: user });
      } else {
        modal.open("premium-required", {
          user_name: user.user_name,
          action: "quick_assessment",
          reason: "not_currently_premium",
        });
      }
    },
    lessons: function (user) {
      if (user == "pick") {
        if (
          app_state.get("sessionUser.supporter_role") &&
          (app_state.get("sessionUser.known_supervisees.length") > 0 ||
            app_state.get("currentUser.managed_orgs.length") > 0)
        ) {
          app_state.controller.send("switch_communicators", {
            header: i18n.t(
              "select_user_to_review_lessons",
              "Select User to Review Trainings"
            ),
            stay: true,
            route: "user.lessons",
          });
          return;
        } else {
          user = app_state.get("currentUser");
        }
      }
      user = user || app_state.get("currentUser");
      this.transitionToRoute("user.lessons", emberGet(user, "id"));
    },
    run_eval: function (user) {
      if (user == "pick") {
        if (
          app_state.get("sessionUser.supporter_role") &&
          (app_state.get("sessionUser.known_supervisees.length") > 0 ||
            app_state.get("currentUser.managed_orgs.length") > 0)
        ) {
          var prompt = i18n.t(
            "select_user_for_eval",
            "Select User for Evaluation"
          );
          app_state.controller.send("switch_communicators", {
            stay: true,
            modeling: false,
            skip_me: !app_state.get(
              "currentUser.subscription.premium_supporter_plus_communicator"
            ),
            header: prompt,
            eval: true,
          });
          return;
        } else {
          user = app_state.get("currentUser");
        }
      }
      app_state
        .check_for_currently_premium(user, "eval", false, true)
        .then(function () {
          app_state.set_speak_mode_user(
            emberGet(user, "id"),
            false,
            false,
            "obf/eval"
          );
        });
    },
    remote_model: function (user) {
      if (user.premium || emberGet(user, "currently_premium")) {
        modal.open("modals/remote-model", { user_id: user.id });
      } else {
        modal.open("premium-required", {
          user_name: user.user_name,
          action: "evaluation",
          reason: "not_currently_premium",
        });
      }
    },
    getting_started: function () {
      //      this.transitionToRoute('setup');
      modal.open("getting-started", {
        progress: app_state.get("currentUser.preferences.progress"),
      });
    },
    record_note: function (user) {
      user = user || app_state.get("currentUser");
      if (!emberGet(user, "avatar_url_with_fallback")) {
        emberSet(
          user,
          "avatar_url_with_fallback",
          emberGet(user, "avatar_url")
        );
      }
      app_state.check_for_needing_purchase().then(function () {
        modal
          .open("record-note", { note_type: "text", user: user })
          .then(function () {
            runLater(function () {
              app_state
                .get("currentUser")
                .reload()
                .then(null, function () {});
            }, 5000);
          });
      });
    },
    sync: function () {
      if (!persistence.get("syncing")) {
        console.debug("syncing because manually triggered");
        persistence.sync("self", true).then(null, function () {});
      } else {
        this.send("sync_details");
      }
    },
    load_reports: function () {
      var user = app_state.get("currentUser");
      this.transitionToRoute("user.stats", user.get("user_name"));
    },
    hide_login: function () {
      app_state.set("login_modal", false);
      $("html,body").css("overflow", "");
      $("#login_overlay").remove();
    },
    show_explanation: function (exp) {
      this.set("show_" + exp + "_explanation", true);
    },
    set_selected: function (selected) {
      this.set("selected", selected);
    },
    set_index_nav: function (nav) {
      if (nav == "main" || nav == "supervisees") {
        var u = app_state.get("currentUser");
        u.set("preferences.device.last_index_nav", nav);
        u.save().then(null, function () {});
      } else if (nav == "updates") {
        if (app_state.get("currentUser")) {
          app_state.set("currentUser.read_notifications", true);
          app_state
            .get("currentUser")
            .save()
            .then(null, function () {});
        }
      }
      this.set("index_nav_state", nav);
    },
    toggle_extras: function () {
      this.set("show_main_extras", !this.get("show_main_extras"));
    },
    expand_left_nav: function () {
      this.set("left_nav_expanded", !this.get("left_nav_expanded"));
    },
    intro_video: function (id) {
      if (window.ga) {
        window.ga("send", "event", "Setup", "video", "Intro video opened");
      }
      modal.open("inline-video", {
        video: { type: "youtube", id: id },
        hide_overlay: true,
      });
    },
    intro: function (user_id) {
      if (window.ga) {
        window.ga("send", "event", "Setup", "start", "Setup started");
      }
      app_state.set("auto_setup", false);

      if (user_id) {
        this.transitionToRoute("setup", {
          queryParams: { user_id: user_id, page: null },
        });
      } else if (
        app_state.get("currentUser.permissions.delete") &&
        (app_state.get("currentUser.supervisees") || []).length > 0
      ) {
        var prompt = i18n.t("setup_which_user", "Select User to Run Setup");
        app_state.controller.send("switch_communicators", {
          stay: true,
          modeling: false,
          setup: true,
          skip_me: false,
          header: prompt,
        });
      } else {
        this.transitionToRoute("setup", {
          queryParams: { user_id: null, page: null },
        });
      }
    },
    opening_index: function () {
      app_state.set("index_view", true);
    },
    closing_index: function () {
      app_state.set("index_view", false);
    },
    manage_supervisors: function () {
      modal.open("supervision-settings", {
        user: app_state.get("currentUser"),
      });
    },
    session_select: function () {
      if (!app_state.get("currentUser.preferences.logging")) {
        this.send("load_reports");
      } else {
        this.send("set_index_nav", "updates");
      }
    },
    sync_details: function () {
      var list = [].concat(persistence.get("sync_log") || []).reverse();
      modal.open("sync-details", { details: list });
    },
    stats: function (user_name) {
      if (!user_name) {
        if ((app_state.get("currentUser.supervisees") || []).length > 0) {
          var prompt = i18n.t(
            "select_user_for_reports",
            "Select User for Reports"
          );
          app_state.controller.send("switch_communicators", {
            stay: true,
            modeling: true,
            skip_me: !app_state.get(
              "currentUser.subscription.premium_supporter_plus_communicator"
            ),
            route: "user.stats",
            header: prompt,
          });
          return;
        } else {
          user_name = app_state.get("currentUser.user_name");
        }
      }
      this.transitionToRoute("user.stats", user_name, {
        queryParams: {
          start: null,
          end: null,
          device_id: null,
          location_id: null,
          split: null,
          start2: null,
          end2: null,
          devicde_id2: null,
          location_id2: null,
        },
      });
    },
    goals: function () {
      if (
        app_state.get("sessionUser.supporter_role") &&
        (app_state.get("sessionUser.known_supervisees.length") > 0 ||
          app_state.get("currentUser.managed_orgs.length") > 0)
      ) {
        var prompt = i18n.t("select_user_for_goals", "Select User for Goals");
        app_state.controller.send("switch_communicators", {
          stay: true,
          modeling: true,
          skip_me: !app_state.get(
            "currentUser.subscription.premium_supporter_plus_communicator"
          ),
          route: "user.goals",
          header: prompt,
        });
        return;
      } else {
        var user_name = app_state.get("currentUser.user_name");
        this.transitionToRoute("user.stats", user_name, {
          queryParams: {
            start: null,
            end: null,
            device_id: null,
            location_id: null,
            split: null,
            start2: null,
            end2: null,
            devicde_id2: null,
            location_id2: null,
          },
        });
      }
    },
    new_dashboard: function () {
      var user = app_state.get("currentUser");
      user.set("preferences.new_index", true);
      user.save().then(null, function () {});
      modal.success(
        i18n.t(
          "revert_new_dashboard",
          "Welcome to the new, cleaner dashboard! If you're not a fan you can switch back on your Preferences page."
        )
      );
    },
    set_goal: function (user) {
      var _this = this;
      CoughDrop.store.findRecord("user", user.id).then(
        function (user_model) {
          modal.open("new-goal", { user: user_model }).then(
            function (res) {
              if (res && res.get("id") && res.get("set_badges")) {
                _this.transitionToRoute(
                  "user.goal",
                  user_model.get("user_name"),
                  res.get("id")
                );
              } else if (res) {
                // update the matching currentUser.supervisees goal attribute
                // with the new value if not already set
                (app_state.get("currentUser.known_supervisees") || []).forEach(
                  function (sup) {
                    if (emberGet(sup, "id") == user_model.get("id")) {
                      emberSet(sup, "goal", {
                        id: res.get("id"),
                        summary: res.get("summary"),
                      });
                    }
                  }
                );
              }
            },
            function () {}
          );
        },
        function (err) {
          modal.error(
            i18n.t(
              "error_loading_user2",
              "There was an unexpected error trying to load the user"
            )
          );
        }
      );
    },
    update_evaluation: function (action) {
      modal.open("modals/eval-status", {
        action: action,
        user: app_state.get("sessionUser"),
      });
    },
    next_lesson: function () {
      var lesson = app_state.get("sessionUser.first_incomplete_lesson");
      if (lesson) {
        var prefix = location.protocol + "//" + location.host;
        if (capabilities.installed_app && capabilities.api_host) {
          prefix = capabilities.api_host;
        }
        window.open(
          prefix +
            "/lessons/" +
            lesson.id +
            "/" +
            lesson.lesson_code +
            "/" +
            app_state.get("sessionUser.user_token"),
          "_blank"
        );
      }
    },
    launch_rating: function () {
      var user = app_state.get("sessionUser");
      if (user) {
        var progress = user.get("preferences.progress") || {};

        progress.rated = new Date().getTime();
        user.set("preferences.progress", progress);
        user.save().then(null, function () {});
      }
      capabilities.launch_rating();
    },
    modeling_ideas: function (user_name) {
      var users = [];
      if (!user_name) {
        if ((app_state.get("currentUser.supervisees") || []).length > 0) {
          (app_state.get("currentUser.known_supervisees") || []).forEach(
            function (u) {
              if (emberGet(u, "premium")) {
                users.push(u);
              }
            }
          );
          // add all supervisees as users
        } else {
          users.push(app_state.get("currentUser"));
        }
      } else {
        (app_state.get("currentUser.known_supervisees") || []).forEach(
          function (u) {
            if (u.user_name == user_name) {
              users.push(u);
            }
          }
        );
      }
      if (users.length > 0) {
        modal.open("modals/modeling-ideas", { users: users });
      }
    },
    set_start_code: function () {
      this.set("start_code", true);
    },
  },
});
