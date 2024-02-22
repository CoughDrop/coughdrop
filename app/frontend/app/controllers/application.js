import Ember from "ember";
import Controller from "@ember/controller";
import EmberObject from "@ember/object";
import { set as emberSet, get as emberGet } from "@ember/object";
import { later as runLater } from "@ember/runloop";
import RSVP from "rsvp";
import $ from "jquery";
import CoughDrop from "../app";
import CoughDropImage from "../models/image";
import app_state from "../utils/app_state";
import stashes from "../utils/_stashes";
import utterance from "../utils/utterance";
import modal from "../utils/modal";
import i18n from "../utils/i18n";
import persistence from "../utils/persistence";
import editManager from "../utils/edit_manager";
import buttonTracker from "../utils/raw_events";
import capabilities from "../utils/capabilities";
import speecher from "../utils/speecher";
import session from "../utils/session";
import obf from "../utils/obf";
import Button from "../utils/button";
import { redirect_to_modern_view } from "../utils/redirect_login";
import { htmlSafe } from "@ember/string";
import { inject } from "@ember/controller";
import { observer } from "@ember/object";
import { computed } from "@ember/object";
import sync from "../utils/sync";
import { inject as service } from "@ember/service";

export default Controller.extend({
  router: service(),
  board: inject("board.index"),
  updateTitle: function (str) {
    if (!Ember.testing) {
      if (str) {
        document.title = str + " - " + CoughDrop.app_name;
      } else {
        document.title = CoughDrop.app_name;
      }
    }
  },
  copy_board: function (decision, for_editing, selected_user_name) {
    var oldBoard = this.get("board").get("model");
    if (!persistence.get("online")) {
      modal.error(
        i18n.t(
          "need_online_for_copying",
          "You must be connected to the Internet to make copies of boards."
        )
      );
      return RSVP.reject();
    }
    // If a board has any sub-boards or if the current user has any supervisees,
    // or if the board is in the current user's board set,
    // then there's a confirmation step before copying.

    // ALSO ask if copy should be public, if the source board is public
    var needs_decision = (oldBoard.get("linked_boards") || []).length > 0;
    if (oldBoard.get("protected_material")) {
      // Protecting boards from being copied is really only a UI constraint,
      // since the user has all the info they need via the API to create
      // their own copy. We just don't make it easy but it's totally doable.
      // As such, there isn't really any protection from this on the backend.
      if (oldBoard.get("copying_state.none")) {
        modal.error(
          i18n.t(
            "cant_copy_protected_boards",
            "This board contains purchased content which can't be copied."
          )
        );
        return RSVP.reject();
      } else {
        needs_decision = true;
      }
    }
    var _this = this;
    needs_decision = needs_decision || !!oldBoard.get("multiple_locales");
    needs_decision =
      needs_decision ||
      (app_state.get("currentUser.supervisees") || []).length > 0;
    needs_decision =
      needs_decision ||
      (app_state.get("currentUser.stats.board_set_ids") || []).indexOf(
        oldBoard.get("id")
      ) >= 0;
    needs_decision = true;

    if (!decision && needs_decision) {
      return modal
        .open("copy-board", {
          board: oldBoard,
          for_editing: for_editing,
          selected_user_name: selected_user_name,
        })
        .then(function (opts) {
          return _this.copy_board(opts, for_editing);
        });
    }
    decision = decision || {};
    decision.user = decision.user || app_state.get("currentUser");
    decision.action = decision.action || "nothing";
    oldBoard.set("copy_name", decision.board_name);
    oldBoard.set("copy_prefix", decision.board_prefix);
    return modal.open("copying-board", {
      board: oldBoard,
      action: decision.action,
      user: decision.user,
      shares: decision.shares,
      symbol_library: decision.symbol_library,
      make_public: decision.make_public,
      default_locale: decision.default_locale,
      translate_locale: decision.translate_locale,
      disconnect: decision.disconnect,
      new_owner: decision.new_owner,
    });
  },
  board_levels: computed(function () {
    return CoughDrop.board_levels.slice(1, 11);
  }),

  isModernViewButtonVisible: computed("router.currentRouteName", function () {
    const currentRoute = this.router.currentRouteName;
    const is_user_name_valid = (session.user_name || "").startsWith("chetu_");
    if (currentRoute === "index" && is_user_name_valid) {
      return true;
    }
    return false;
  }),

  level_description: computed(
    "board_levels",
    "board.current_level",
    function () {
      var level = this.get("board.current_level");
      var desc = (
        this.get("board_levels").find(function (l) {
          return l.id.toString() == level.toString();
        }) || {}
      ).name;
      if (desc) {
        desc = htmlSafe(desc.replace(/-/, "<br/>"));
      }
      return null; //desc;
    }
  ),
  update_level_buttons: observer(
    "board.current_level",
    "board.model.button_set.id",
    "app_state.speak_mode",
    function () {
      var _this = this;
      if (this.get("board.model") && !app_state.get("speak_mode")) {
        this.get("board.model")
          .load_button_set()
          .then(
            function (bs) {
              _this.set(
                "level_buttons",
                bs.buttons_for_level(
                  _this.get("board.model.id"),
                  _this.get("board.current_level")
                )
              );
            },
            function () {}
          );
      }
    }
  ),
  show_board_intro: computed(
    "has_board_intro",
    "app_state.feature_flags.find_multiple_buttons",
    "app_state.currentUser.preferences.progress.board_intros",
    "app_state.pairing",
    "board.model.id",
    function () {
      // true if has_board_intro AND board intro hasn't been viewed yet
      if (
        this.get("has_board_intro") &&
        app_state.get("feature_flags.find_multiple_buttons") &&
        !app_state.get("pairing")
      ) {
        var found = false;
        var board_id = this.get("board.model.id");
        var intros =
          app_state.get("currentUser.preferences.progress.board_intros") || [];
        if (
          intros.find(function (i) {
            return i == board_id;
          })
        ) {
          found = true;
        }
        return !found;
      }
      return false;
    }
  ),
  has_board_intro: computed(
    "stashes.root_board_state.id",
    "stashes.temporary_root_board_state.id",
    "app_state.currentUser.preferences.home_board.id",
    "board.model.intro",
    "board.model.intro.unapproved",
    function () {
      // TODO: also show if checking out the board in the
      // setup process (except that's really only under
      // advanced now), or if enabled on the embed
      var root_board =
        stashes.get("root_board_state.id") == this.get("board.model.id") ||
        stashes.get("temporary_root_board_state.id") ==
          this.get("board.model.id");
      // TODO: option to set board level for board_intro prompt
      // TODO: when entering board intro, set root_board_state to the board's id
      return (
        root_board &&
        this.get("board.model.intro") &&
        !this.get("board.model.intro.unapproved")
      );
    }
  ),
  speak_mode_needing_hammer_js: computed("app_state.speak_mode", function () {
    // iOS needs hammer.js because it's an older version of safari,
    // this causes problems when in speak mode and with dropdowns
    // since we get double-hit events
    return (
      app_state.get("speak_mode") &&
      capabilities.installed_app &&
      capabilities.system == "iOS"
    );
  }),
  highlight_button: function (buttons, button_set, options) {
    options = options || {};
    if (buttons && buttons != "resume") {
      this.set("button_highlights", buttons);
      this.set("button_highlights_button_set", button_set);
      this.set("last_highlight_selection", null);
      this.set("last_highlight_explore_action", new Date().getTime());
      this.set("last_highlight_options", options);
      utterance.set("hint_button", null);
      modal.close();
      if (options.wait_to_prompt) {
        modal.notice(
          i18n.t(
            "find_sentence_box_hint",
            "Try to find each word as it appears in the sentence box above"
          ),
          true
        );
      }
    } else if (buttons == "resume") {
      options = this.get("last_highlight_options") || options;
    }
    var _this = this;
    var defer = _this.get("highlight_button_defer") || RSVP.defer();
    runLater(function () {
      var will_render = false;
      if (defer.revert_board_level == undefined && buttons != "resume") {
        defer.revert_board_level = stashes.get("board_level") || "none";
        var was = stashes.get("board_level");
        var level_changed =
          stashes.get("board_level") && stashes.get("board_level") != 10;
        if (level_changed) {
          _this.send("set_level", 10);
          will_render = true;
        }
      }
      _this.set("highlight_button_defer", defer);
      if (!defer.promise.registered) {
        defer.promise.registered = true;
        defer.wait_a_bit = function (timeout) {
          if (!defer.promise.already_waiting_a_bit) {
            defer.promise.already_waiting_a_bit = true;
            runLater(function () {
              defer.promise.already_waiting_a_bit = false;
              _this.highlight_button("resume");
            }, timeout);
          }
        };
        defer.promise
          .then(null, function (err) {
            console.error("highlight sequence failed", err);
            _this.set("button_highlights", null);
            return RSVP.resolve();
          })
          .then(function () {
            if (_this.get("highlight_button_defer") == defer) {
              _this.set("highlight_button_defer", null);
              _this.set("last_highlight_selection", null);
              _this.set("last_highlight_explore_action", null);
              _this.set("last_highlight_options", null);
              utterance.set("hint_button", null);
              if (defer.revert_board_level) {
                var new_level = 10;
                if (defer.revert_board_level == "none") {
                  new_level = 10;
                } else {
                  new_level = defer.revert_board_level;
                }
                var level_changed = stashes.get("board_level") != new_level;
                var was = stashes.get("board_level");
                if (level_changed) {
                  _this.send("set_level", new_level);
                }
              }
            }
          });
      }
      if (options.wait_to_prompt) {
        options.delay_prompt = true;
        var now = new Date().getTime();
        var last_action =
          _this.get("last_highlight_selection") ||
          _this.get("last_highlight_explore_action") ||
          now;
        var waiting_duration = new Date().getTime() - last_action;
        var factor = defer.already_waited
          ? 0.3
          : defer.not_first_action
          ? 1.0
          : 1.5;
        options.picture_hint = true;
        if (waiting_duration > 1000) {
          // afteer 1 second change the sentence box hint to the right picture
        }
        if (waiting_duration > 5000 * factor) {
          // afte 5 seconds do a subtle highlight
          options.subtle_highlight = true;
          options.delay_prompt = false;
          defer.wait_a_bit(1000);
          defer.did_wait = true;
        }
        if (waiting_duration > 10000 * factor) {
          // after 10 seconds do a strong highlight
          options.subtle_highlight = false;
        }
        var button_highlights = _this.get("button_highlights") || [];
        var next_actual_button = button_highlights.find(function (b) {
          return b.actual_button;
        });
        if (next_actual_button) {
          utterance.set("hint_button", utterance.get("hint_button") || {});
          utterance.set("hint_button.label", next_actual_button.label);
        } else {
          utterance.set("hint_button", null);
        }
      }
      if (!will_render) {
        _this.send("highlight_button", options);
      }
    });
    return defer.promise;
  },
  allow_search: computed(
    "app_state.domain_settings.full_domain",
    "session.isAuthenticated",
    function () {
      return (
        app_state.get("domain_settings.full_domain") ||
        session.get("isAuthenticated")
      );
    }
  ),
  setup_for_other: computed(
    "app_state.currentUser.id",
    "setup_user_id",
    function () {
      if (
        this.get("setup_user_id") &&
        this.get("setup_user_id") != app_state.get("currentUser.id")
      ) {
        return CoughDrop.store.peekRecord("user", this.get("setup_user_id"));
      } else {
        return null;
      }
    }
  ),
  can_edit_from_speak_mode: computed(
    "app_state.sessionUser",
    "app_state.sessionUser.modeling_only",
    "app_state.referenced_user.preferences.speak_mode_edit",
    "board.model.permissions.edit",
    "board.model.uncopyable",
    "board.model.for_sale",
    function () {
      if (
        app_state.get("sessionUser") &&
        !app_state.get("sessionUser.modeling_only") &&
        app_state.get("referenced_user.preferences.speak_mode_edit")
      ) {
        if (this.get("board.model.permissions.edit")) {
          return true;
        } else if (
          !this.get("board.model.for_sale") &&
          !this.get("board.model.uncopyable")
        ) {
          return true;
        }
      }
      return false;
    }
  ),
  no_hidden_buttons: computed(
    "stashes.all_buttons_enabled",
    "board.model.hidden_buttons",
    function () {
      if (stashes.get("all_buttons_enabled")) {
        return false;
      }
      return !this.get("board.model.hidden_buttons");
    }
  ),
  actions: {
    onMoveToModernView() {
      redirect_to_modern_view();
    },
    invalidateSession: function () {
      session.invalidate(true);
    },
    authenticateSession: function () {
      if (location.hostname == "127.0.0.1") {
        this.transitionToRoute("login");
        // location.href = "//localhost:" + location.port + "/login";
      } else if (location.hostname == "www.mycoughdrop.com") {
        location.href = "//app.mycoughdrop.com/login";
      } else {
        this.transitionToRoute("login");
      }
    },
    cancel_sync: function () {
      persistence.cancel_sync();
    },
    index: function () {
      app_state.return_to_index();
    },
    support: function () {
      modal.open("support");
    },
    language: function () {
      modal.open("modals/choose-locale");
    },
    stickSidebar: function () {
      var user = app_state.get("currentUser");
      user.set(
        "preferences.quick_sidebar",
        !user.get("preferences.quick_sidebar")
      );
      stashes.persist("sidebarEnabled", false);
      user.save().then(null, function () {});
    },
    toggleSidebar: function () {
      stashes.persist("sidebarEnabled", !stashes.get("sidebarEnabled"));
    },
    hide_temporary_sidebar: function () {
      if (
        stashes.get("sidebarEnabled") &&
        !app_state.get("currentUser.preferences.quick_sidebar")
      ) {
        this.send("toggleSidebar");
      }
    },
    searchBoards: function () {
      if (this.get("searchString") == "home") {
        this.transitionToRoute("home-boards");
      } else {
        this.transitionToRoute(
          "search",
          "any",
          encodeURIComponent(this.get("searchString") || "_")
        );
      }
    },
    backspace: function (opts) {
      app_state.set("last_activation", new Date().getTime());
      utterance.backspace(opts);
      if (!opts || !opts.skip_click) {
        if (
          app_state.get("currentUser.preferences.click_buttons") &&
          app_state.get("speak_mode")
        ) {
          speecher.click();
        }
        if (
          app_state.get("currentUser.preferences.vibrate_buttons") &&
          app_state.get("speak_mode")
        ) {
          capabilities.vibrate();
        }
      }
    },
    clear: function (opts) {
      app_state.set("last_activation", new Date().getTime());
      app_state.toggle_modeling(false);
      utterance.clear(opts);
      if (!opts || !opts.skip_click) {
        if (
          app_state.get("currentUser.preferences.click_buttons") &&
          app_state.get("speak_mode")
        ) {
          speecher.click();
        }
        if (
          app_state.get("currentUser.preferences.vibrate_buttons") &&
          app_state.get("speak_mode")
        ) {
          capabilities.vibrate();
        }
      }
    },
    toggle_home_lock: function () {
      app_state.toggle_home_lock();
    },
    toggle_all_buttons: function () {
      var state = stashes.get("all_buttons_enabled");
      if (state) {
        stashes.persist("all_buttons_enabled", null);
        sync.send_update(
          app_state.get("referenced_user.id") ||
            app_state.get("currentUser.id"),
          { assertion: { show_all: false } }
        );
      } else {
        stashes.persist("all_buttons_enabled", true);
        sync.send_update(
          app_state.get("referenced_user.id") ||
            app_state.get("currentUser.id"),
          { assertion: { show_all: true } }
        );
      }
    },
    toggle_focus: function () {
      if (app_state.get("focus_words")) {
        app_state.set("focus_words", null);
        editManager.controller.model.set("focus_id", "blank");
        if (app_state.get("pairing") || app_state.get("followers.allowed")) {
          sync.send_update(
            app_state.get("referenced_user.id") ||
              app_state.get("currentUser.id"),
            { assertion: { focus_words: [] } }
          );
        }
      } else {
        modal.open("modals/focus-words", {
          user: app_state.get("sessionUser"),
          root_board_id: stashes.get("root_board_state.id"),
          inactivity_timeout: true,
        });
      }
    },
    end_evaluation: function () {
      obf.eval.conclude();
    },
    assessment_settings: function () {
      obf.eval.settings();
    },
    change_section: function (direction) {
      obf.eval.move(direction);
    },
    jump_section: function () {
      obf.eval.jump_to();
    },
    repeat_prompt: function () {
      var model = this.get("board.model");
      runLater(function () {
        model.prompt();
      }, 100);
    },
    home: function (opts) {
      app_state.set("last_activation", new Date().getTime());
      opts = opts || {};
      if (app_state.get("eval_mode") && app_state.get("speak_mode")) {
        modal.notice(
          i18n.t(
            "eval_mode_home_disabled",
            "Home is disabled during an evaluation, you can end the evaluation using the menu icon"
          ),
          true
        );
        return;
      }
      var state =
        stashes.get("temporary_root_board_state") ||
        stashes.get("root_board_state");
      var current = app_state.get("currentBoardState");
      this.set("last_highlight_explore_action", new Date().getTime());
      // if you're on a temporary home board and you hit home, it should take you to the real home
      if (
        state &&
        current &&
        state.key == current.key &&
        stashes.get("temporary_root_board_state")
      ) {
        stashes.persist("temporary_root_board_state", null);
        state = stashes.get("root_board_state");
      }
      if (state && current && state.key == current.key) {
        editManager.clear_history();
        if (state == stashes.get("temporary_root_board_state")) {
          modal.notice(
            i18n.t(
              "already_temporary_home",
              "This board was set as the home board temporarily. To cancel hit the icon in the top right corner and select 'Release Home Lock'."
            ),
            true
          );
        } else {
          if (state.meta_home) {
            modal.notice(
              i18n.t(
                "already_home2",
                "You are already on the home board. To return to the home board list, hit the icon in the top right corner."
              ),
              true
            );
          } else {
            modal.notice(
              i18n.t(
                "already_home",
                "You are already on the home board. To exit Speak Mode hit the icon in the top right corner."
              ),
              true
            );
          }
          this.highlight_button("resume");
        }
      } else {
        if (stashes.get("sticky_board") && app_state.get("speak_mode")) {
          modal.warning(
            i18n.t(
              "sticky_board_notice",
              "Board lock is enabled, disable to leave this board."
            ),
            true
          );
        } else {
          app_state.track_depth("home");
          this.rootBoard({
            index_as_fallback: true,
            button_triggered: opts.button_triggered,
          });
          if (
            app_state.get("currentUser.preferences.click_buttons") &&
            app_state.get("speak_mode")
          ) {
            speecher.click();
          }
          if (
            app_state.get("currentUser.preferences.vibrate_buttons") &&
            app_state.get("speak_mode")
          ) {
            capabilities.vibrate();
          }
        }
      }
    },
    jump: function (path, source, board) {
      if (stashes.get("sticky_board") && app_state.get("speak_mode")) {
        modal.warning(
          i18n.t(
            "sticky_board_notice",
            "Board lock is enabled, disable to leave this board."
          ),
          true
        );
      } else {
        this.jumpToBoard({
          key: path,
          source: source,
          level: board.level,
          locale: board.locale,
          home_lock: board.home_lock,
          meta_home: board.meta_home,
        });
      }
    },
    setAsHome: function (option, user) {
      var _this = this;
      user = user || app_state.get("currentUser");
      if (
        option == "starting" &&
        app_state.controller.get("setup_user_id") &&
        app_state.controller.get("setup_user_id") != "self" &&
        user != "skip_lookup"
      ) {
        CoughDrop.store
          .findRecord("user", app_state.controller.get("setup_user_id"))
          .then(
            function (u) {
              _this.send("setAsHome", option, u);
            },
            function (err) {
              _this.send("setAsHome", option, "skip_lookup");
            }
          );
        return;
      }
      app_state.check_for_needing_purchase().then(function () {
        app_state.assert_source().then(
          function () {
            var board = _this.get("board.model");
            if (option == "starting") {
              board =
                stashes.get("root_board_state") ||
                _this.get("board").get("model");
            }
            var board_user_name = emberGet(board, "key").split(/\//)[1];
            var preferred_symbols =
              user.get("preferences.preferred_symbols") || "original";
            var needs_confirmation =
              user.get("supervisees") ||
              preferred_symbols != "original" ||
              board_user_name != user.get("user_name");
            var done = function (sync) {
              if (
                sync &&
                persistence.get("online") &&
                persistence.get("auto_sync")
              ) {
                _this.set("simple_board_header", false);
                runLater(function () {
                  if (persistence.get("auto_sync")) {
                    console.debug("syncing because home board changes");
                    persistence
                      .sync("self", null, null, "home_board_changed")
                      .then(null, function () {});
                  }
                }, 1000);
                if (_this.get("setup_footer")) {
                  _this.send("setup_go", "forward");
                } else {
                  modal.success(
                    i18n.t(
                      "board_set_as_home",
                      "Great! This is now the user's home board!"
                    ),
                    true
                  );
                }
              } else {
                if (_this.get("setup_footer")) {
                  _this.send("setup_go", "forward");
                }
              }
            };
            if (needs_confirmation && !option) {
              modal
                .open("set-as-home", {
                  board: board,
                  user_id: _this.get("setup_user_id"),
                })
                .then(
                  function (res) {
                    if (res && res.updated) {
                      done(true);
                    }
                  },
                  function () {}
                );
            } else {
              if (user) {
                if (option == "starting") {
                  user.copy_home_board(board, true).then(
                    function () {},
                    function () {
                      modal.error(
                        i18n.t(
                          "set_as_home_failed",
                          "Home board update failed unexpectedly"
                        )
                      );
                    }
                  );
                  done();
                } else {
                  user.set("preferences.home_board", {
                    id: emberGet(board, "id"),
                    level: stashes.get("board_level"),
                    locale: app_state.get("label_locale"), // optional locale, otherwise server will assign board's locale
                    key: emberGet(board, "key"),
                  });
                  user.save().then(
                    function () {
                      done(true);
                    },
                    function () {
                      modal.error(
                        i18n.t(
                          "set_as_home_failed",
                          "Home board update failed unexpectedly"
                        )
                      );
                    }
                  );
                }
              }
            }
          },
          function () {}
        );
      });
    },
    add_to_sidebar: function () {
      var _this = this;
      app_state.check_for_needing_purchase().then(function () {
        app_state.assert_source().then(
          function () {
            var board = _this.get("board").get("model");
            modal.open("add-to-sidebar", {
              board: {
                name: board.get("name"),
                key: board.get("key"),
                levels: board.get("levels"),
                home_lock: false,
                image: board.get("image_url"),
              },
            });
          },
          function () {}
        );
      });
    },
    adjust_level: function (direction) {
      var prior_level = parseInt(this.get("board.current_level"), 10);
      var level = prior_level || 10;
      if (direction == "plus") {
        level = Math.min(10, level + 1);
      } else {
        level = Math.max(1, level - 1);
      }
      if (level != prior_level) {
        this.send("set_level", level);
      }
      // Can't think of a cleaner way to prevent the dropdown
      // from closing when hitting plus or minus, but still
      // closing if they hit outside the dropdown
      $("#level_dropdown").attr("data-toggle", "");
      setTimeout(function () {
        $("#level_dropdown").attr("data-toggle", "dropdown");
      }, 500);
    },
    set_level: function (level) {
      stashes.persist("board_level", level);
      this.set("board.preview_level", level);
      this.set("board.model.display_level", level);
      editManager.process_for_displaying();
    },
    clear_overrides: function () {
      if (this.get("board.model.permissions.edit")) {
        this.get("board.model")
          .clear_overrides()
          .then(
            function () {
              editManager.process_for_displaying();
            },
            function () {
              modal.error(
                i18n.t(
                  "error_clearing_overrides",
                  "There was an unexpected error while clearing overrides"
                )
              );
            }
          );
      }
    },
    stopMasquerading: function () {
      var data = session.restore();
      data.user_name = data.original_user_name;
      delete data.original_user_name;
      delete data.as_user_id;
      session.persist(data).then(function () {
        location.reload();
      });
    },
    back: function (opts) {
      // TODO: true back button vs. separate history? one is better for browser,
      // other is better if you end up with intermediate pages at all.. what about
      // full screen browser mode? Prolly needs a localstorage component as well,
      // since if I reload and then click the browser back button it's all kinds
      // of backward.
      app_state.set("last_activation", new Date().getTime());
      if (stashes.get("sticky_board") && app_state.get("speak_mode")) {
        modal.warning(
          i18n.t(
            "sticky_board_notice",
            "Board lock is enabled, disable to leave this board."
          ),
          true
        );
      } else {
        app_state.track_depth("back");
        this.backOneBoard(opts);
        if (!opts || !opts.skip_click) {
          if (
            app_state.get("currentUser.preferences.click_buttons") &&
            app_state.get("speak_mode")
          ) {
            speecher.click();
          }
          if (
            app_state.get("currentUser.preferences.vibrate_buttons") &&
            app_state.get("speak_mode")
          ) {
            capabilities.vibrate();
          }
        }
      }
      this.set("last_highlight_explore_action", new Date().getTime());
    },
    board_intro: function () {
      modal.open("modals/board-intro", {
        board: this.get("board.model"),
        step: 0,
      });
    },
    vocalize: function (opts) {
      app_state.set("last_activation", new Date().getTime());
      this.vocalize(null, opts);
    },
    remote_modeling: function () {
      if (app_state.get("pairing.user_id")) {
        modal.open("modals/remote-model", {
          communicator: !app_state.get("pairing.partner"),
          user_id: app_state.get("pairing.user_id"),
        });
      } else {
        modal.error(
          i18n.t("remote_modeling_error", "Error loading remote modeling")
        );
      }
    },
    alert: function () {
      utterance.alert({ button_triggered: true });
      this.send("hide_temporary_sidebar");
    },
    special: function (opts) {
      // sidebar actions
      if (opts.action == ":app") {
        if (
          capabilities.installed_app &&
          (capabilities.system == "iOS" || capabilities.system == "Android")
        ) {
          capabilities.apps.launch(opts.arg).then(null, function (err) {
            modal.error(
              i18n.t("app_launch_failed", "App failed to launch"),
              true
            );
          });
        } else {
          modal.error(
            i18n.t(
              "no_app_launches",
              "App launches not available in this view"
            ),
            true
          );
        }
      } else {
        var obj = {
          label: opts.name,
          vocalization: opts.action,
          prevent_return: true,
          button_id: null,
          source: "click",
          board: {
            id: app_state.get("currentBoardState.id"),
            parent_id: app_state.get("currentBoardState.parent_id"),
            key: app_state.get("currentBoardState.key"),
          },
          type: "speak",
        };
        app_state.activate_button(obj, obj);
      }
    },
    setSpeakModeUser: function (id, type) {
      app_state.set_speak_mode_user(id, false, type == "modeling");
    },
    pickSpeakModeUser: function (type) {
      var prompt = i18n.t("speak_as_which_user", "Select User to Speak As");
      if (type == "modeling") {
        prompt = i18n.t("model_for_which_user", "Select User to Model For");
      }
      app_state.set("referenced_speak_mode_user", null);
      this.send("switch_communicators", {
        modeling: type == "modeling",
        stay: true,
        header: prompt,
      });
    },
    toggleSpeakMode: function (decision) {
      app_state.toggle_speak_mode(decision);
    },
    startRecording: function () {
      // currently-speaking user must have active paid subscription to do video recording
      app_state
        .check_for_currently_premium(
          app_state.get("speakModeUser"),
          "record_session"
        )
        .then(
          function () {
            alert("not yet implemented");
          },
          function () {}
        );
    },
    toggleEditMode: function (decision) {
      if (!app_state.get("edit_mode")) {
        if (
          app_state.get("speak_mode") &&
          app_state.get("currentUser.preferences.require_speak_mode_pin") &&
          app_state.get("currentUser.preferences.speak_mode_pin")
        ) {
          modal.open("speak-mode-pin", {
            actual_pin: app_state.get("currentUser.preferences.speak_mode_pin"),
            action: "edit",
            hide_hint: app_state.get("currentUser.preferences.hide_pin_hint"),
          });
        } else {
          app_state.toggle_edit_mode(decision);
        }
      } else {
        app_state.check_for_needing_purchase().then(
          function () {
            app_state.toggle_edit_mode(decision);
          },
          function () {}
        );
      }
    },
    editBoardDetails: function () {
      if (!app_state.get("edit_mode")) {
        return;
      }
      modal.open("edit-board-details", { board: this.get("board.model") });
    },
    toggle_sticky_board: function () {
      stashes.persist("sticky_board", !stashes.get("sticky_board"));
    },
    toggle_pause_logging: function () {
      var ts = new Date().getTime();
      if (stashes.get("logging_paused_at")) {
        ts = null;
      }
      stashes.persist("logging_paused_at", ts);
    },
    switch_communicators: function (opts) {
      var ready = RSVP.resolve({ correct_pin: true });
      if (
        app_state.get("speak_mode") &&
        app_state.get("currentUser.preferences.require_speak_mode_pin") &&
        app_state.get("currentUser.preferences.speak_mode_pin")
      ) {
        ready = modal.open("speak-mode-pin", {
          actual_pin: app_state.get("currentUser.preferences.speak_mode_pin"),
          action: "none",
          hide_hint: app_state.get("currentUser.preferences.hide_pin_hint"),
        });
      }
      ready.then(
        function (res) {
          if (res && res.correct_pin) {
            modal.open("switch-communicators", opts || {});
          }
        },
        function () {}
      );
    },
    find_button: function () {
      var include_other_boards =
        app_state.get("speak_mode") &&
        (stashes.get("root_board_state") || {}).key ==
          app_state.get("currentUser.preferences.home_board.key");
      modal.open("find-button", {
        inactivity_timeout: app_state.get("speak_mode"),
        board: this.get("board").get("model"),
        include_other_boards: include_other_boards,
      });
    },
    shareBoard: function () {
      var _this = this;
      app_state.assert_source().then(
        function () {
          modal.open("share-board", { board: _this.get("board.model") });
        },
        function () {}
      );
    },
    copy_and_edit_board: function () {
      var _this = this;
      app_state.check_for_needing_purchase().then(
        function () {
          _this.copy_board(null, true).then(
            function (board) {
              if (board) {
                app_state.jump_to_board({
                  id: board.id,
                  key: board.key,
                });
                runLater(function () {
                  app_state.toggle_edit_mode();
                });
              }
            },
            function () {}
          );
        },
        function () {}
      );
    },
    tweakBoard: function (decision) {
      var _this = this;
      var update_locale = null;
      if (decision && decision.update_locale) {
        update_locale = decision.update_locale;
        decision = null;
      }
      app_state.check_for_needing_purchase().then(
        function () {
          app_state.assert_source().then(
            function () {
              if (app_state.get("edit_mode")) {
                app_state.toggle_mode("edit");
              }
              _this.copy_board(decision).then(
                function (board) {
                  if (board) {
                    stashes.persist("label_locale", update_locale);
                    stashes.persist("vocalization_locale", update_locale);
                    stashes.persist("override_label_locale", update_locale);
                    stashes.persist(
                      "override_vocalization_locale",
                      update_locale
                    );
                    if (update_locale) {
                      app_state.set("label_locale", update_locale);
                      app_state.set("vocalization_locale", update_locale);
                    }
                    app_state.jump_to_board({
                      id: board.id,
                      key: board.key,
                    });
                  }
                },
                function () {}
              );
            },
            function () {}
          );
        },
        function () {}
      );
    },
    downloadBoard: function () {
      var _this = this;
      app_state.assert_source().then(
        function () {
          var has_links =
            _this.get("board").get("model").get("linked_boards").length > 0;
          modal.open("download-board", {
            type: "obf",
            has_links: has_links,
            id: _this.get("board.model.id"),
          });
        },
        function () {}
      );
    },
    printBoard: function () {
      var _this = this;
      app_state.assert_source().then(
        function () {
          var has_links =
            _this.get("board").get("model").get("linked_boards").length > 0;
          modal.open("download-board", {
            type: "pdf",
            has_links: has_links,
            id: _this.get("board.model.id"),
          });
        },
        function () {}
      );
    },
    saveBoard: function () {
      this.get("board").saveButtonChanges();
    },
    resetBoard: function () {
      this.toggleMode("edit");
      this.get("board").get("model").rollbackAttributes();
      this.get("board").processButtons();
    },
    undoEdit: function () {
      editManager.undo();
    },
    redoEdit: function () {
      editManager.redo();
    },
    modifyGrid: function (action, type, location) {
      if (location == "top" || location == "left") {
        location = 0;
      } else {
        location = null;
      }
      editManager.modify_size(type, action, location);
    },
    noPaint: function () {
      editManager.clear_paint_mode();
    },
    paint: function (fill, border, parts_of_speech) {
      if (fill == "level") {
        modal.open("modals/paint-level", {});
      } else {
        var part_of_speech = (parts_of_speech || [])[0];
        editManager.set_paint_mode(fill, border, part_of_speech);
      }
    },
    star: function () {
      var _this = this;
      app_state.assert_source().then(
        function () {
          var board = _this.get("board").get("model");
          if (board.get("starred")) {
            board.unstar();
          } else {
            board.star();
          }
        },
        function () {}
      );
    },
    check_scanning: function () {
      app_state.check_scanning();
    },
    boardDetails: function () {
      modal.open("board-details", { board: this.get("board.model") });
    },
    set_locale: function (loc) {
      app_state.set("label_locale", loc);
      app_state.set("vocalization_locale", loc);
      stashes.persist("label_locale", loc);
      stashes.persist("vocalization_locale", loc);
      stashes.persist("override_label_locale", loc);
      stashes.persist("override_vocalization_locale", loc);
      editManager.process_for_displaying();
    },
    openButtonStash: function () {
      if (!app_state.get("edit_mode")) {
        return;
      }
      editManager.clear_paint_mode();
      modal.open("button-stash");
    },
    preview_levels: function () {
      if (!app_state.get("edit_mode")) {
        return;
      }
      editManager.preview_levels();
    },
    shift_level: function (direction) {
      var levels = this.get("board.button_levels");
      if (levels[0] != 1) {
        levels.unshift(1);
      }
      if (levels[levels.length - 1] != 10) {
        levels.push(10);
      }
      if (direction == "done") {
        editManager.clear_preview_levels();
      } else if (direction == "down") {
        var lvl = Math.max(1, (this.get("board.current_level") || 10) - 1);
        var new_level = null;
        for (var idx = 0; idx < levels.length; idx++) {
          if (levels[idx] <= lvl) {
            new_level = levels[idx];
          }
        }
        this.set("board.preview_level", new_level);
        this.set("board.model.display_level", new_level);
        editManager.apply_preview_level(new_level);
      } else if (direction == "up") {
        var lvl = Math.min(10, (this.get("board.current_level") || 10) + 1);
        var new_level = null;
        for (var idx = 0; idx < levels.length; idx++) {
          if (!new_level && levels[idx] >= lvl) {
            new_level = levels[idx];
          }
        }
        this.set("board.preview_level", new_level);
        this.set("board.model.display_level", new_level);
        editManager.apply_preview_level(new_level);
      }
    },
    list_copies: function () {
      modal.open("board-copies", { board: this.get("board.model") });
    },
    board_actions: function () {
      modal.open("modals/board-actions", { board: this.get("board.model") });
    },
    highlight_button: function (options) {
      options = options || {};
      // TODO: this and activateButton belong somewhere more testable
      var buttons = this.get("button_highlights");
      var defer = this.get("highlight_button_defer") || RSVP.defer();
      this.set("highlight_button_defer", defer);

      var _this = this;
      var picture_prompt = function ($button) {
        if (utterance.get("hint_button")) {
          utterance.set(
            "hint_button.label",
            $button.find(".button-label").eq(0).text()
          );
          utterance.set(
            "hint_button.image_url",
            $button.find(".symbol").attr("src")
          );
        }
      };

      if (buttons && buttons.length > 0) {
        var button = buttons[0];
        if (
          button.pre == "home" ||
          button.pre == "true_home" ||
          button.pre == "home" ||
          button.pre == "sidebar"
        ) {
          // handle pre-buttons if there are any
          this.set("button_highlights", buttons);
          var $button = $("#speak > button:first");
          if (button.pre == "sidebar") {
            $button = $(
              "#sidebar a[data-key='" + button.linked_board_key + "']"
            );
          }
          if (options.delay_prompt) {
            defer.wait_a_bit(500);
            return;
          }
          modal
            .highlight($button, {
              clear_overlay: options.subtle_highlight,
              highlight_type: "button_search",
            })
            .then(
              function () {
                _this.set("last_highlight_selection", new Date().getTime());
                if (defer.did_wait) {
                  defer.already_waited = true;
                }
                defer.not_first_action = true;

                if (button.pre == "true_home" || button.pre == "home") {
                  var has_temporary_home = !!stashes.get(
                    "temporary_root_board_state"
                  );
                  var already_on_temporary_home =
                    stashes.get("temporary_root_board_state.id") ==
                    app_state.get("currentBoardState.id");
                  if (!has_temporary_home || already_on_temporary_home) {
                    buttons.shift();
                  }
                  _this.send("home");
                } else if (button.pre == "temp_home") {
                  buttons.shift();
                  _this.send("home");
                } else {
                  buttons.shift();
                  _this.jumpToBoard({
                    key: button.linked_board_key,
                    home_lock: button.home_lock,
                    meta_home: button.meta_home,
                  });
                }
              },
              function (err) {
                if (
                  err &&
                  (err.reason == "force close" || err.highlight_close)
                ) {
                  runLater(function () {
                    var not_highlighting =
                      (modal.highlight_settings || {}).highlight_type ==
                        "button_search" && !modal.is_open("highlight");
                    not_highlighting =
                      not_highlighting ||
                      ((modal.highlight2_settings || {}).highlight_type ==
                        "button_search" &&
                        !modal.is_open("highlight-secondary"));
                    if (not_highlighting) {
                      _this.highlight_button("resume");
                    }
                  }, 1000);
                } else {
                  defer.reject(err || { canceled: true });
                }
              }
            );
        } else if (
          button &&
          button.board_id == this.get("board.model").get("id")
        ) {
          // otherwise if you're currently on the correct board
          var findButtonElem = function () {
            if (button.board_id == _this.get("board.model").get("id")) {
              var $button = $(".button[data-id='" + button.id + "']");
              if ($button[0] && $button.width()) {
                // Find the (visible) button in the UI
                if (options.picture_hint) {
                  picture_prompt($button);
                }
                if (options.delay_prompt) {
                  defer.wait_a_bit(500);
                  return;
                }
                _this.set("button_highlights", buttons);
                modal
                  .highlight($button, {
                    clear_overlay: options.subtle_highlight,
                    highlight_type: "button_search",
                  })
                  .then(
                    function () {
                      if (defer.did_wait) {
                        defer.already_waited = true;
                      }
                      defer.not_first_action = true;
                      _this.set(
                        "last_highlight_selection",
                        new Date().getTime()
                      );
                      buttons.shift();
                      var found_button = editManager.find_button(button.id);
                      var board = _this.get("board.model");
                      _this.activateButton(found_button, {
                        board: board,
                        skip_highlight_check: true,
                      });
                      var next_button = buttons[0];
                      if (
                        next_button &&
                        (next_button.board_id == board.id || next_button.pre)
                      ) {
                        // If there is more to the sequence, and the
                        // user selection isn't going to involve loading
                        // a different board, then call highlight_button again
                        _this.highlight_button("resume");
                      } else if (
                        next_button &&
                        next_button.board_id != board.id
                      ) {
                        // If there is more to the sequence but we're
                        // in the process of navigating, do nothing, the
                        // load board process should highlight the next
                        // step on its own
                      } else {
                        // If there aren't any more valid steps, end the sequence
                        defer.resolve();
                      }
                    },
                    function (err) {
                      if (
                        err &&
                        (err.reason == "force close" || err.highlight_close)
                      ) {
                        runLater(function () {
                          var not_highlighting =
                            (modal.highlight_settings || {}).highlight_type ==
                              "button_search" && !modal.is_open("highlight");
                          not_highlighting =
                            not_highlighting ||
                            ((modal.highlight2_settings || {}).highlight_type ==
                              "button_search" &&
                              !modal.is_open("highlight-secondary"));
                          if (not_highlighting) {
                            _this.highlight_button("resume");
                          }
                        }, 1000);
                      } else {
                        defer.reject(err || { canceled: true });
                      }
                    }
                  );
              } else {
                // If you can't find the correct button, try again in a minute
                runLater(findButtonElem, 100);
              }
            }
          };
          findButtonElem();
        } else {
          // looks like we're on the wrong board...
          // pull hint buttons from the list until we find the next
          // actual_button,
          button = buttons.shift();
          while (button && !button.actual_button) {
            button = buttons.shift();
          }
          if (button && _this.get("button_highlights_button_set")) {
            // try to find the sequence to get from here to there
            var bs = _this.get("button_highlights_button_set");
            var current = _this.get("board.model.id");
            var home = stashes.get("root_board_state.id");
            var tmp_home = stashes.get("temporary_root_board_state.id");
            var map = bs.board_map([bs]).map;
            var sequence = bs.button_steps(
              current,
              button.board_id,
              map,
              home,
              tmp_home
            );
            var new_buttons = [];
            if (sequence.pre == "true_home") {
              new_buttons.push({ pre: "true_home" });
            }
            sequence.buttons.forEach(function (btn) {
              new_buttons.push(btn);
            });
            new_buttons.push(button);
            while (new_buttons.length > 0) {
              buttons.unshift(new_buttons.pop());
            }
            runLater(function () {
              _this.highlight_button("resume");
            });
          } else {
            // nothing to do, give up
            defer.reject({ error: "no buttons left to guide to" });
          }
        }
      } else {
        defer.resolve();
      }
    },
    about_modal: function () {
      modal.open("about-coughdrop");
    },
    full_screen: function () {
      capabilities.fullscreen(true).then(null, function () {
        modal.warning(
          i18n.t("fullscreen_failed", "Full Screen Mode failed to load"),
          true
        );
      });
    },
    launch_board: function () {
      if (app_state.get("board_url")) {
        capabilities.window_open(app_state.get("board_url"), "_blank");
      }
    },
    confirm_update: function () {
      modal.open("confirm-update-app");
    },
    toggle_modeling: function () {
      app_state.toggle_modeling_if_possible(true);
    },
    meta_home_click: function () {},
    meta_home: function () {
      app_state.meta_home_if_possible();
    },
    switch_languages: function () {
      modal
        .open("switch-languages", { board: this.get("board.model") })
        .then(function (res) {
          if (res && res.switched) {
            editManager.process_for_displaying();
          }
        });
    },
    back_to_from_route: function () {
      if (app_state.get("from_route")) {
        this.transitionToRoute.apply(this, app_state.get("from_route"));
      } else {
        app_state.return_to_index();
      }
    },
    suggestions: function () {
      modal.open("button-suggestions", {
        board: this.get("board.model"),
        user: app_state.get("currentUser"),
      });
    },
    setup_go: function (direction) {
      var order = this.get("setup_order");
      var current = this.get("setup_page") || "intro";
      var current_index = order.indexOf(current) || 0;
      var wait = RSVP.resolve();
      if (direction == "forward") {
        var u = app_state.get("setup_user") || app_state.get("currentUser");
        if (order[current_index + 1] == "board_category") {
          // Skip board selection if a home board is already
          // set and this was an auto-launch
          if (
            app_state.get("auto_setup") &&
            u &&
            u.get("preferences.home_board")
          ) {
            current_index++;
          }
        }
        if (order[current_index] == "symbols") {
          if (
            u &&
            u.get("preferred_symbols_changed") &&
            u.get("preferences.preferred_symbols") != "original"
          ) {
            var promise = u.swap_home_board_images();
            if (promise.wait) {
              wait = promise;
            }
          }
        }
        current_index = Math.min(current_index + 1, order.length - 1);
        if (window.ga && current_index > (this.get("max_index") || 0)) {
          this.set("max_index", current_index);
          console.log("progression", this.get("max_index"));
          window.ga(
            "send",
            "event",
            "Setup",
            "step_" + this.get("max_index"),
            "Progressed to Step " + this.get("max_index")
          );
        }
      } else if (direction == "backward") {
        current_index = Math.max(current_index - 1, 0);
      }
      var _this = this;
      wait.then(
        function () {
          var params = { page: order[current_index] };
          var user_id = _this.get("setup_user_id");
          if (user_id) {
            params.user_id = user_id;
          }
          _this.transitionToRoute("setup", { queryParams: params });
        },
        function () {}
      );
    },
    speak_mode_notification: function () {
      if (app_state.get("speak_mode_modeling_ideas.enabled")) {
        modal.open("modals/modeling-ideas", {
          inactivity_timeout: true,
          speak_mode: true,
          users: [app_state.get("referenced_user")],
        });
      } else if (app_state.get("user_badge")) {
        modal.open("badge-awarded", {
          inactivity_timeout: true,
          speak_mode: true,
          badge: { id: app_state.get("user_badge.id") },
        });
      } else if (app_state.get("speak_mode_modeling_ideas.timeout")) {
        modal.open("modals/modeling-ideas", {
          inactivity_timeout: true,
          speak_mode: true,
          users: [app_state.get("referenced_user")],
        });
      }
    },
  },
  setup_next: computed("setup_page", "setup_order", function () {
    if (this.get("setup_order")) {
      return (
        this.get("setup_page") !=
        this.get("setup_order")[this.get("setup_order").length - 1]
      );
    }
  }),
  setup_previous: computed("setup_page", "setup_order", function () {
    if (this.get("setup_order")) {
      return !!(
        this.get("setup_page") &&
        this.get("setup_page") != this.get("setup_order")[0]
      );
    }
  }),
  setup_index: computed("setup_order", "setup_page", function () {
    var order = this.get("setup_order");
    var current = this.get("setup_page") || "intro";
    return (order.indexOf(current) || 0) + 1;
  }),
  activateButton: function (button, options) {
    var _this = this;
    button.findContentLocally().then(
      function () {
        options = options || {};
        var image = options.image || button.get("image");
        var sound = options.sound || button.get("sound");
        var board = options.board;

        var oldState = {
          id: board.get("id"),
          key: board.get("key"),
          parent_id: board.get("parent_board_id"),
        };
        var image_url = button.image;
        if (image && image.get("personalized_url") && !button.no_skin) {
          image_url = image.get("personalized_url");
        } else if (
          button.get("original_image_url") &&
          CoughDropImage.personalize_url
        ) {
          image_url = CoughDropImage.personalize_url(
            button.get("original_image_url"),
            app_state.get("currentUser.user_token"),
            app_state.get("referenced_user.preferences.skin"),
            button.no_skin
          );
        }
        var obj = {
          label: button.label,
          vocalization: button.vocalization,
          image: image_url,
          button_id: button.id,
          part_of_speech: button.part_of_speech,
          sound:
            (sound && sound.get("url")) || button.get("original_sound_url"),
          board: oldState,
          completion: button.completion,
          source: options.trigger_source,
          blocking_speech: button.blocking_speech,
          type: "speak",
        };
        if (options.overlay_location) {
          obj.overlay_location = options.overlay_location;
        } else if (
          options.event &&
          options.event.swipe_direction &&
          options.swipe_direction != "clear"
        ) {
          obj.swipe_location = options.event.swipe_direction;
          var grid = editManager.grid_for(button.id);
          var inflection = (grid || []).find(function (i) {
            return i.location == options.event.swipe_direction;
          });
          if (inflection) {
            options.overlay_label = inflection.label;
            options.overlay_vocalization = inflection.vocalization;
          }
          button = editManager.overlay_button_from(button);
        }

        obj.label = options.overlay_label || obj.label;
        obj.vocalization = options.overlay_vocalization || obj.vocalization;
        if (options.event && options.event.overlay_target) {
          obj.overlay = options.event.overlay_target;
        }
        if (options.event && options.event.trigger_source) {
          obj.source = options.event.trigger_source;
        }
        var location = buttonTracker.locate_button_on_board(
          button.id,
          options.event
        );
        if (location) {
          obj.percent_x = location.percent_x;
          obj.percent_y = location.percent_y;
          obj.prior_percent_x = location.prior_percent_x;
          obj.prior_percent_y = location.prior_percent_y;
          obj.percent_travel = location.percent_travel;
        }
        _this.set("last_highlight_explore_action", new Date().getTime());

        // if this is the next actual_button in the highlight
        // queue then shift off everything up to and including that button
        var highlight_buttons = _this.get("button_highlights") || [];
        var next_actual_button = highlight_buttons.find(function (b) {
          return b.actual_button;
        });
        utterance.set("hint_button", null);
        if (
          !options.skip_highlight_check &&
          next_actual_button &&
          (!button.load_board || button.link_disabled) &&
          (next_actual_button.vocalization || next_actual_button.label) ==
            (button.vocalization || button.label)
        ) {
          // If we hit a button that works without being prompted,
          // move on to the next actual button and wait again
          var btn = null;
          while (btn != next_actual_button) {
            btn = highlight_buttons.shift();
          }
          _this.set("highlight_buttons", highlight_buttons);
          var defer = _this.get("highlight_button_defer");
          if (defer) {
            defer.already_waited = false;
            defer.did_wait = false;
            defer.not_first_action = true;
          }
        }
        app_state.activate_button(button, obj);
      },
      function () {}
    );
  },
  background_class: computed(
    "app_state.speak_mode",
    "app_state.currentUser.preferences.board_background",
    "app_state.currentUser.preferences.dim_header",
    "board.model.dim_header",
    function () {
      var res = "";
      if (app_state.get("speak_mode")) {
        var color = app_state.get("currentUser.preferences.board_background");
        if (color) {
          if (color == "#000") {
            color = "black";
          }
          res = res + "color_" + color;
        }
        if (app_state.get("currentUser.preferences.dim_level")) {
          res = res + " " + app_state.get("currentUser.preferences.dim_level");
        }
        if (
          app_state.get("currentUser.preferences.dim_header") ||
          this.get("board.model.dim_header")
        ) {
          res = res + " dim_sides";
        }
      }
      return htmlSafe(res);
    }
  ),
  set_and_say_buttons: function (buttons) {
    utterance.set_and_say_buttons(buttons);
  },
  few_supervisees: computed(
    "app_state.currentUser.supervisees",
    "app_state.currentBoardState.key",
    function () {
      var max_to_show = 2;
      var sups = app_state.get("currentUser.supervisees") || [];
      var list = sups;
      var more = [];
      var current_board_user_name = (
        app_state.get("currentBoardState.key") || ""
      ).split(/\//)[0];
      if (current_board_user_name) {
        var new_list = [];
        var new_more = [];
        sups.forEach(function (sup) {
          if (sup.user_name == current_board_user_name) {
            new_list.push(sup);
          } else {
            new_more.push(sup);
          }
        });
        // don't rearrange if all will be shown anyway, since that would be confusing
        if (
          new_list.length > 0 &&
          new_list.length + new_more.length <= max_to_show
        ) {
          list = new_list;
          more = new_more;
        }
      }
      if (list.length > max_to_show) {
        return null;
      }
      return {
        list: list,
        more: more.length > 0,
      };
    }
  ),
  sayLouder: function (pct) {
    this.vocalize(pct || 3.0);
  },
  vocalize: function (volume, opts) {
    if (app_state.get("eval_mode")) {
      if (this.get("board.model")) {
        this.get("board.model").prompt();
      }
    } else if (app_state.get("currentUser.preferences.repair_on_vocalize")) {
      modal.open("modals/repairs", {
        inactivity_timeout: true,
        speak_on_done: true,
      });
    } else {
      utterance.vocalize_list(volume, opts);
      if (
        app_state.get("currentUser.preferences.vibrate_buttons") &&
        app_state.get("speak_mode")
      ) {
        capabilities.vibrate();
      }
    }
  },
  jumpToBoard: function (new_state, old_state) {
    app_state.jump_to_board(new_state, old_state);
  },
  backOneBoard: function (opts) {
    app_state.back_one_board(opts);
  },
  rootBoard: function (options) {
    app_state.jump_to_root_board(options);
  },
  toggleMode: function (mode, opts) {
    app_state.toggle_mode(mode, opts);
  },
  swatch_style: computed("swatches", function () {
    var swatches = this.get("swatches");
    var extra_rows = (swatches[1].extras || []).length;
    var width = 285 + extra_rows * 60;
    return htmlSafe("width: " + width + "px;");
  }),
  swatches: computed(
    "app_state.colored_keys",
    "app_state.extra_colored_keys",
    function () {
      var res = [].concat(CoughDrop.keyed_colors);
      var extras = app_state.get("extra_colored_keys") || [];
      var extras_per_row = Math.ceil(extras.length / (res.length / 2));
      res.forEach(function (swatch, idx) {
        if (idx % 2 == 1) {
          emberSet(swatch, "right_edge", true);
        }
        if (idx % 2 == 1 && extras_per_row > 0 && extras.length > 0) {
          var list = [];
          for (var idx = 0; idx < extras_per_row; idx++) {
            var extra = extras.shift();
            if (extra) {
              list.push(extra);
            }
          }
          emberSet(swatch, "extras", list);
        } else {
          emberSet(swatch, "extras", null);
        }
      });
      return res;
    }
  ),
  show_back: computed(
    "app_state.empty_board_history",
    "app_state.currentUser.preferences.device.always_show_back",
    "app_state.eval_mode",
    "app_state.currentBoardState.extra_back",
    function () {
      return (
        !this.get("app_state.empty_board_history") ||
        this.get("app_state.currentUser.preferences.device.always_show_back") ||
        this.get("eval_mode") ||
        app_state.get("currentBoardState.extra_back")
      );
    }
  ),
  on_home: computed(
    "stashes.root_board_state.id",
    "app_state.currentBoardState.id",
    "app_state.eval_mode",
    function () {
      return !!(
        (app_state.get("currentBoardState.id") &&
          app_state.get("currentBoardState.id") ==
            stashes.get("root_board_state.id")) ||
        app_state.get("eval_mode")
      );
    }
  ),
  button_list_class: computed(
    "stashes.ghost_utterance",
    "stashes.working_vocalization",
    "stashes.root_board_state.text_direction",
    "extras.eye_gaze_state",
    "show_back",
    "app_state.pairing",
    "app_state.currentUser.preferences.device.button_text_position",
    "app_state.currentUser.preferences.device.utterance_text_only",
    "app_state.currentUsser.preferences.high_contrast",
    "board.text_style",
    "board.button_style",
    "app_state.header_size",
    "app_state.flipped",
    "app_state.currentUser.preferences.device.flipped_override",
    function () {
      var res = "button_list ";
      var flipped = app_state.get("flipped");
      if (flipped) {
        res = res + "flipped ";
        // always show text-only when flipping
      }
      if (stashes.get("ghost_utterance") && !flipped) {
        res = res + "ghost_utterance ";
      }
      if (this.get("extras.eye_gaze_state")) {
        res = res + "with_eyes ";
      }
      if (this.get("show_back")) {
        res = res + "with_back ";
      }
      if (
        speecher.text_direction() == "rtl" ||
        stashes.get("root_board_state.text_direction") == "rtl"
      ) {
        res = res + "rtl ";
      }
      if (app_state.get("pairing")) {
        res = res + "paired ";
      }
      var text_position =
        app_state.get("currentUser.preferences.device.button_text_position") ||
        window.user_preferences.device.button_text_position;
      var show_always =
        app_state.get("currentUser.preferences.device.utterance_text_only") ||
        window.user_preferences.device.utterance_text_only ||
        app_state.get("pairing.partner");
      if (text_position == "text_only" || show_always || flipped) {
        res = res + "text_only ";
      }
      if (app_state.get("currentUser.preferences.high_contrast")) {
        res = res + "high_contrast ";
      }

      if (
        app_state.get("flipped") &&
        app_state.get("currentUser.preferences.device.flipped_override") &&
        app_state.get("currentUser.preferences.device.flipped_text")
      ) {
        res =
          res +
          "text_" +
          app_state.get("currentUser.preferences.device.flipped_text") +
          " ";
      } else {
        if (this.get("board.text_style")) {
          var style = this.get("board.text_style") || " ";
          var big_header =
            this.get("app_state.header_size") == "large" ||
            this.get("app_state.header_size") == "huge";
          if (
            flipped &&
            big_header &&
            (style == " " || style == "text_small" || style == "text_medium")
          ) {
            style = "text_large";
          }
          res = res + style + " ";
        }
      }
      if (this.get("board.button_style")) {
        var style = Button.style(this.get("board.button_style"));
        if (style.upper) {
          res = res + "upper ";
        } else if (style.lower) {
          res = res + "lower ";
        }
        if (style.font_class) {
          res = res + style.font_class + " ";
        }
      }
      if (stashes.get("working_vocalization.length")) {
        res = res + "has_content ";
      }

      return htmlSafe(res);
    }
  ),
  no_paint_mode_class: computed("board.paint_mode", function () {
    var res = "btn ";
    if (this.get("board.paint_mode")) {
      res = res + "btn-default";
    } else {
      res = res + "btn-info";
    }
    return res;
  }),
  paint_mode_class: computed("board.paint_mode", function () {
    var res = "btn ";
    if (this.get("board.paint_mode")) {
      res = res + "btn-info";
    } else {
      res = res + "btn-default";
    }
    return res;
  }),
  undo_class: computed("board.noUndo", function () {
    var res = "skinny ";
    if (this.get("board.noUndo")) {
      res = res + "disabled";
    }
    return res;
  }),
  redo_class: computed("board.noRedo", function () {
    var res = "skinny ";
    if (this.get("board.noRedo")) {
      res = res + "disabled";
    }
    return res;
  }),
  content_class: computed(
    "app_state.sidebar_visible",
    "app_state.index_view",
    "session.isAuthenticated",
    "app_state.currentUser.preferences.new_index",
    function () {
      var res = "";
      if (this.get("app_state.sidebar_visible")) {
        res = res + "with_sidebar ";
      }
      if (this.get("app_state.index_view")) {
        res = res + "index ";
      }
      if (this.get("session.isAuthenticated")) {
        res = res + "with_user ";
      } else if (app_state.get("domain_settings.full_domain")) {
        res = res + "no_user ";
      } else {
        res = res + "blank_user ";
      }
      if (
        app_state.get("browser") == "Safari" ||
        app_state.get("system") == "iOS" ||
        capabilities.system == "iOS"
      ) {
        res = res + "low_for_high_contrast ";
      }
      res = res + "new_index ";
      return res;
    }
  ),
  header_class: computed(
    "app_state.header_size",
    "app_state.speak_mode",
    "app_state.currentUser.preferences.new_index",
    function () {
      var res = "row ";
      res = res + "new_index ";
      if (this.get("app_state.header_size")) {
        res = res + this.get("app_state.header_size") + " ";
      }
      if (this.get("app_state.speak_mode")) {
        res = res + "speaking advanced_selection";
      }
      return res;
    }
  ),
});
