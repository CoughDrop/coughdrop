import Ember from 'ember';
import CoughDrop from '../app';
import app_state from '../utils/app_state';
import stashes from '../utils/_stashes';
import utterance from '../utils/utterance';
import modal from '../utils/modal';
import i18n from '../utils/i18n';
import persistence from '../utils/persistence';
import editManager from '../utils/edit_manager';
import buttonTracker from '../utils/raw_events';
import capabilities from '../utils/capabilities';
import speecher from '../utils/speecher';
import session from '../utils/session';
import Button from '../utils/button';

export default Ember.Controller.extend({
  board: Ember.inject.controller('board.index'),
  slideoutService: Ember.inject.service('slideout-service'),
  updateTitle: function(str) {
    if(!Ember.testing) {
      if(str) {
        document.title = str + " - CoughDrop";
      } else {
        document.title = "CoughDrop";
      }
    }
  },
  copy_board: function(decision, for_editing, selected_user_name) {
    var oldBoard = this.get('board').get('model');
    if(!persistence.get('online')) {
      modal.error(i18n.t('need_online_for_copying', "You must be connected to the Internet to make copies of boards."));
      return Ember.RSVP.reject();
    }
    if(oldBoard.get('protected')) {
      modal.error(i18n.t('cant_copy_protected_boards', "This board contains purchased content, and can't be copied."));
      return Ember.RSVP.reject();
    }
    // If a board has any sub-boards or if the current user has any supervisees,
    // or if the board is in the current user's board set,
    // then there's a confirmation step before copying.

    // ALSO ask if copy should be public, if the source board is public
    var needs_decision = (oldBoard.get('linked_boards') || []).length > 0;
    var _this = this;
    needs_decision = needs_decision || (app_state.get('currentUser.supervisees') || []).length > 0;
    needs_decision = needs_decision || (app_state.get('currentUser.stats.board_set_ids') || []).indexOf(oldBoard.get('id')) >= 0;
    needs_decision = true;

    if(!decision && needs_decision) {
      return modal.open('copy-board', {board: oldBoard, for_editing: for_editing, selected_user_name: selected_user_name}).then(function(opts) {
        return _this.copy_board(opts, for_editing);
      });
    }
    decision = decision || {};
    decision.user = decision.user || app_state.get('currentUser');
    decision.action = decision.action || "nothing";
    return modal.open('copying-board', {board: oldBoard, action: decision.action, user: decision.user, shares: decision.shares, make_public: decision.make_public, translate_locale: decision.translate_locale});
  },
  actions: {
    // Open/close the board editor slideout when visible.
    toggleBoardEditorSlideout: function() {
      this.get('slideoutService').emitToggleSlideout();
    },
    invalidateSession: function() {
      session.invalidate(true);
    },
    authenticateSession: function() {
      this.transitionToRoute('login');
    },
    index: function() {
      this.transitionToRoute('index');
    },
    support: function() {
      modal.open('support');
    },
    stickSidebar: function() {
      var user = app_state.get('currentUser');
      user.set('preferences.quick_sidebar', !user.get('preferences.quick_sidebar'));
      stashes.persist('sidebarEnabled', false);
      user.save().then(null, function() { });
    },
    toggleSidebar: function() {
      stashes.persist('sidebarEnabled', !stashes.get('sidebarEnabled'));
    },
    hide_temporary_sidebar: function() {
      if(stashes.get('sidebarEnabled') && !app_state.get('currentUser.preferences.quick_sidebar')) {
        this.send('toggleSidebar');
      }
    },
    searchBoards: function() {
      if(this.get('searchString') == 'home') {
        this.transitionToRoute('home-boards');
      } else {
        this.transitionToRoute('search', encodeURIComponent(this.get('searchString') || '_'));
      }
    },
    backspace: function() {
      utterance.backspace();
    },
    clear: function() {
      app_state.toggle_modeling(false);
      utterance.clear();
    },
    toggle_home_lock: function() {
      app_state.toggle_home_lock();
    },
    toggle_all_buttons: function() {
      var state = stashes.get('all_buttons_enabled');
      if(state) {
        stashes.persist('all_buttons_enabled', null);
      } else {
        stashes.persist('all_buttons_enabled', true);
      }
    },
    home: function() {
      var state = stashes.get('temporary_root_board_state') || stashes.get('root_board_state');
      var current = app_state.get('currentBoardState');
      // if you're on a temporary home board and you hit home, it should take you to the real home
      if(state && current && state.key == current.key && stashes.get('temporary_root_board_state')) {
        stashes.persist('temporary_root_board_state', null);
        state = stashes.get('root_board_state');
      }
      if(state && current && state.key == current.key) {
        editManager.clear_history();
        if(state == stashes.get('temporary_root_board_state')) {
          modal.notice(i18n.t('already_temporary_home', "This board was set as the home board temporarily. To cancel hit the icon in the top right corner and select 'Release Home Lock'."), true);
        } else {
          modal.notice(i18n.t('already_home', "You are already on the home board. To exit Speak Mode hit the icon in the top right corner."), true);
        }
      } else {
        if(stashes.get('sticky_board') && app_state.get('speak_mode')) {
          modal.warning(i18n.t('sticky_board_notice', "Board lock is enabled, disable to leave this board."), true);
        } else {
          this.rootBoard({index_as_fallback: true});
        }
      }
    },
    jump: function(path, source, board) {
      if(stashes.get('sticky_board') && app_state.get('speak_mode')) {
        modal.warning(i18n.t('sticky_board_notice', "Board lock is enabled, disable to leave this board."), true);
      } else {
        this.jumpToBoard({
          key: path,
          home_lock: board.home_lock
        });
      }
    },
    setAsHome: function() {
      var board = this.get('board').get('model');
      if(app_state.get('currentUser.supervisees')) {
        modal.open('set-as-home', {board: board});
      } else {
        var user = app_state.get('currentUser');
        if(user) {
          user.set('preferences.home_board', {
            id: board.get('id'),
            key: board.get('key')
          });
          var _this = this;
          user.save().then(function() {
            if(persistence.get('online')) {
              Ember.run.later(function() {
              console.debug('syncing because home board changes');
                persistence.sync('self').then(null, function() { });
              }, 1000);
            }
          }, function() {
            modal.error(i18n.t('set_as_home_failed', "Home board update failed unexpectedly"));
          });
        }
      }
    },
    add_to_sidebar: function() {
      var board = this.get('board').get('model');
      modal.open('add-to-sidebar', {board: {
        name: board.get('name'),
        key: board.get('key'),
        home_lock: false,
        image: board.get('image_url')
      }});
    },
    stopMasquerading: function() {
      var data = session.restore();
      data.user_name = data.original_user_name;
      delete data.original_user_name;
      delete data.as_user_id;
      session.persist(data);
      location.reload();
    },
    back: function() {
      // TODO: true back button vs. separate history? one is better for browser,
      // other is better if you end up with intermediate pages at all.. what about
      // full screen browser mode? Prolly needs a localstorage component as well,
      // since if I reload and then click the browser back button it's all kinds
      // of backward.
      if(stashes.get('sticky_board') && app_state.get('speak_mode')) {
        modal.warning(i18n.t('sticky_board_notice', "Board lock is enabled, disable to leave this board."), true);
      } else {
        this.backOneBoard();
      }
    },
    vocalize: function() {
      this.vocalize();
    },
    alert: function() {
      utterance.alert();
      this.send('hide_temporary_sidebar');
    },
    setSpeakModeUser: function(id) {
      app_state.set_speak_mode_user(id);
    },
    toggleSpeakMode: function(decision) {
      app_state.toggle_speak_mode(decision);
    },
    startRecording: function() {
      // currently-speaking user must have active paid subscription to do video recording
      app_state.check_for_full_premium(app_state.get('speakModeUser'), 'record_session').then(function() {
        alert("not yet implemented");
      }, function() { });
    },
    toggleEditMode: function(decision) {
      app_state.check_for_really_expired(app_state.get('sessionUser')).then(function() {
        app_state.toggle_edit_mode(decision);
      }, function() { });
    },
    editBoardDetails: function() {
      if(!app_state.get('edit_mode')) { return; }
      modal.open('edit-board-details', {board: this.get('board.model')});
    },
    toggle_sticky_board: function() {
      stashes.persist('sticky_board', !stashes.get('sticky_board'));
    },
    toggle_pause_logging: function() {
      var ts = (new Date()).getTime();
      if(stashes.get('logging_paused_at')) {
        ts = null;
      }
      stashes.persist('logging_paused_at', ts);
    },
    switch_communicators: function() {
      var ready = Ember.RSVP.resolve({correct_pin: true});
      if(app_state.get('currentUser.preferences.require_speak_mode_pin') && app_state.get('currentUser.preferences.speak_mode_pin')) {
        ready = modal.open('speak-mode-pin', {actual_pin: app_state.get('currentUser.preferences.speak_mode_pin'), action: 'none'});
      }
      ready.then(function(res) {
        if(res && res.correct_pin) {
          modal.open('switch-communicators');
        }
      }, function() { });
    },
    find_button: function() {
      var include_other_boards = app_state.get('speak_mode') && ((stashes.get('root_board_state') || {}).key) == app_state.get('currentUser.preferences.home_board.key');
      modal.open('find-button', {
        board: this.get('board').get('model'),
        include_other_boards: include_other_boards
      });
    },
    deleteBoard: function(decision) {
      if(!decision) {
        this.send('confirmDeleteBoard');
      } else {
        modal.close(decision != 'cancel');
        if(decision == 'cancel') { return; }
        var board = this.get('board').get('model');
        board.deleteRecord();
        board.save().then(null, function() { });
        this.transitionToRoute('index');
      }
    },
    renameBoard: function() {
      modal.open('rename-board', {board: this.get('board').get('model')});
    },
    shareBoard: function() {
      if(this.get('board.model.protected')) {
        modal.error(i18n.t('cant_share_protected_boards', "This board contains purchased content, and can't be shared."));
        return;
      }
      modal.open('share-board', {board: this.get('board').get('model')});
    },
    copy_and_edit_board: function() {
      var _this = this;
      app_state.check_for_really_expired(app_state.get('sessionUser')).then(function() {
        _this.copy_board(null, true).then(function(board) {
          if(board) {
            app_state.jump_to_board({
              id: board.id,
              key: board.key
            });
            Ember.run.later(function() {
              app_state.toggle_edit_mode();
            });
          }
        }, function() { });
      }, function() { });
    },
    tweakBoard: function(decision) {
      var _this = this;
      app_state.check_for_really_expired(app_state.get('sessionUser')).then(function() {
        if(app_state.get('edit_mode')) {
          app_state.toggle_mode('edit');
        }
        _this.copy_board(decision).then(function(board) {
          if(board) {
            app_state.jump_to_board({
              id: board.id,
              key: board.key
            });
          }
        }, function() { });
      }, function() { });
    },
    downloadBoard: function() {
      var has_links = this.get('board').get('model').get('linked_boards').length > 0;
      modal.open('download-board', {type: 'obf', has_links: has_links, id: this.get('board.model.id')});
    },
    printBoard: function() {
      var has_links = this.get('board').get('model').get('linked_boards').length > 0;
      modal.open('download-board', {type: 'pdf', has_links: has_links, id: this.get('board.model.id')});
    },
    saveBoard: function() {
      this.get('board').saveButtonChanges();
    },
    resetBoard: function() {
      this.toggleMode('edit');
      this.get('board').get('model').rollbackAttributes();
      this.get('board').processButtons();
    },
    undoEdit: function() {
      editManager.undo();
    },
    redoEdit: function() {
      editManager.redo();
    },
    modifyGrid: function(action, type, location) {
      if(location == 'top' || location == 'left') {
        location = 0;
      } else {
        location = null;
      }
      editManager.modify_size(type, action, location);
    },
    noPaint: function() {
      editManager.clear_paint_mode();
    },
    paint: function(fill, border, parts_of_speech) {
      var part_of_speech = (parts_of_speech || [])[0];
      editManager.set_paint_mode(fill, border, part_of_speech);
    },
    star: function() {
      var board = this.get('board').get('model');
      if(board.get('starred')) {
        board.unstar();
      } else {
        board.star();
      }
    },
    check_scanning: function() {
      app_state.check_scanning();
    },
    boardDetails: function() {
      modal.open('board-details', {board: this.get('board.model')});
    },
    openButtonStash: function() {
      if(!app_state.get('edit_mode')) { return; }
      modal.open('button-stash');
    },
    list_copies: function() {
      modal.open('board-copies', {board: this.get('board.model')});
    },
    highlight_button: function() {
      // TODO: this and activateButton belong somewhere more testable
      var buttons = this.get('button_highlights');
      var _this = this;
      if(buttons && buttons.length > 0) {
        var button = buttons[0];
        if(button.pre == 'home' || button.pre == 'sidebar') {
          buttons.shift();
          this.set('button_highlights', buttons);
          var $button = Ember.$("#speak > button:first");
          if(button.pre == 'sidebar') {
            $button = Ember.$("#sidebar a[data-key='" + button.linked_board_key + "']");
          }
          modal.highlight($button).then(function() {
            if(button.pre == 'home') {
              _this.send('home');
            } else {
              _this.jumpToBoard({
                key: button.linked_board_key,
                home_lock: button.home_lock
              });
            }
          });
        } else if(button && button.board_id == this.get('board.model').get('id')) {
          var findButtonElem = function() {
            if(button.board_id == _this.get('board.model').get('id')) {
              var $button = Ember.$(".button[data-id='" + button.id + "']");
              if($button[0]) {
                buttons.shift();
                _this.set('button_highlights', buttons);
                modal.highlight($button).then(function() {
                  var found_button = editManager.find_button(button.id);
                  var board = _this.get('board.model');
                  _this.activateButton(found_button, {image: found_button.get('image'), sound: found_button.get('sound'), board: board});
                });
              } else {
                // TODO: really? is this the best you can figure out?
                Ember.run.later(findButtonElem, 100);
              }
            }
          };
          findButtonElem();
        }
      }
    },
    about_modal: function() {
      modal.open('about-coughdrop');
    },
    full_screen: function() {
      capabilities.fullscreen(true).then(null, function() {
        modal.warning(i18n.t('fullscreen_failed', "Full Screen Mode failed to load"), true);
      });
    },
    confirm_update: function() {
      modal.open('confirm-update-app');
    },
    toggle_modeling: function() {
      app_state.toggle_modeling(true);
    }
  },
  activateButton: function(button, options) {
    options = options || {};
    var image = options.image;
    var sound = options.sound;
    var board = options.board;

    var oldState = {
      id: board.get('id'),
      key: board.get('key')
    };
    var obj = {
      label: button.label,
      vocalization: button.vocalization,
      image: (image && image.get('personalized_url')) || button.image,
      button_id: button.id,
      sound: (sound && sound.get('url')),
      board: oldState,
      completion: button.completion,
      blocking_speech: button.blocking_speech,
      type: 'speak'
    };
    var location = buttonTracker.locate_button_on_board(button.id, options.event);
    if(location) {
      obj.percent_x = location.percent_x;
      obj.percent_y = location.percent_y;
    }

    app_state.activate_button(button, obj);
  },
  background_class: function() {
    if(app_state.get('speak_mode')) {
      var color = app_state.get('currentUser.preferences.board_background');
      if(color) {
        if(color == '#000') { color = 'black'; }
        return "color_" + color;
      }
    }
    return "";
  }.property('app_state.speak_mode', 'app_state.currentUser.preferences.board_background'),
  set_and_say_buttons: function(buttons) {
    utterance.set_and_say_buttons(buttons);
  },
  sayLouder: function() {
    this.vocalize(3.0);
  },
  vocalize: function(volume) {
    utterance.vocalize_list(volume);
  },
  voiceList: function() {
    var res = [];
    var current_locale = (window.navigator.language || "").replace(/-/g, '_').toLowerCase();
    var current_lang = current_locale.split(/_/)[0];
    speecher.get('voices').forEach(function(v, idx) {
      var name = v.name;
      if(v.lang) {
        name = v.name + " (" + v.lang + ")";
      }
      var locale = (v.lang || "").replace(/-/g, '_').toLowerCase();
      var lang = locale.split(/_/)[0];
      res.push({
        id: v.voiceURI || (v.name + " " + v.lang),
        name: name,
        locale: locale,
        lang: lang,
        index: idx
      });
    });
    // show most-likely candidates at the top
    return res.sort(function(a, b) {
      var a_first = false;
      var b_first = false;
      if(a.locale == current_locale && b.locale != current_locale) {
        a_first = true;
      } else if(b.locale == current_locale && a.locale != current_locale) {
        b_first = true;
      } else if(a.lang == current_lang && b.lang != current_lang) {
        a_first = true;
      } else if(b.lang == current_lang && a.lang != current_lang) {
        b_first = true;
      }
      if(a_first) {
        return -1;
      } else if(b_first) {
        return 1;
      } else {
        return a.index - b.index;
        // right now we're keeping the same order they came in, assuming there was
        // some reasoning behind the browser's order of voices..
//         if(a.name < b.name) {
//           return -1;
//         } else if(a.name > b.name) {
//           return 1;
//         } else {
//           return 0;
//         }
      }
    });
  }.property('speecher.voices'),
  jumpToBoard: function(new_state, old_state) {
    app_state.jump_to_board(new_state, old_state);
  },
  backOneBoard: function() {
    app_state.back_one_board();
  },
  rootBoard: function(options) {
    app_state.jump_to_root_board(options);
  },
  toggleMode: function(mode, opts) {
    app_state.toggle_mode(mode, opts);
  },
  swatches: function() {
    return [].concat(CoughDrop.keyed_colors);
  }.property('app_state.colored_keys'),
  button_list_class: function() {
    var res = "button_list ";
    if(stashes.get('ghost_utterance')) {
      res = res + "ghost_utterance ";
    }
    if(this.get('extras.eye_gaze_state')) {
      res = res + "with_eyes ";
    }
    if(!this.get('app_state.empty_board_history')) {
      res = res + "with_back ";
    }
    return res;
  }.property('stashes.ghost_utterance', 'extras.eye_gaze_state', 'app_state.empty_board_history'),
  no_paint_mode_class: function() {
    var res = "btn ";
    if(this.get('board.paint_mode')) {
      res = res + "btn-default";
    } else {
      res = res + "btn-info";
    }
    return res;
  }.property('board.paint_mode'),
  paint_mode_class: function() {
    var res = "btn ";
    if(this.get('board.paint_mode')) {
      res = res + "btn-info";
    } else {
      res = res + "btn-default";
    }
    return res;
  }.property('board.paint_mode'),
  undo_class: function() {
    var res = "skinny ";
    if(this.get('board.noUndo')) {
      res = res + "disabled";
    }
    return res;
  }.property('board.noUndo'),
  redo_class: function() {
    var res = "skinny ";
    if(this.get('board.noRedo')) {
      res = res + "disabled";
    }
    return res;
  }.property('board.noRedo'),
  content_class: function() {
    var res = "";
    if(this.get('app_state.sidebar_visible')) {
      res = res + "with_sidebar ";
    }
    if(this.get('app_state.index_view')) {
      res = res + "index ";
    }
    if(this.get('session.isAuthenticated')) {
      res = res + "with_user ";
    } else {
      res = res + "no_user ";
    }
    return res;
  }.property('app_state.sidebar_visible', 'app_state.index_view', 'session.isAuthenticated'),
  header_class: function() {
    var res = "row ";
    if(this.get('app_state.header_size')) {
      res = res + this.get('app_state.header_size') + ' ';
    }
    if(this.get('app_state.speak_mode')) {
      res = res + 'speaking advanced_selection';
    }
    return res;
  }.property('app_state.header_size', 'app_state.speak_mode')
});
