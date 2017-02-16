import Ember from 'ember';
import i18n from '../../utils/i18n';
import app_state from '../../utils/app_state';
import utterance from '../../utils/utterance';
import capabilities from '../../utils/capabilities';
import buttonTracker from '../../utils/raw_events';
import modal from '../../utils/modal';
import persistence from '../../utils/persistence';
import Button from '../../utils/button';

import CoughDrop from '../../app';
import editManager from '../../utils/edit_manager';

export default Ember.Controller.extend({
  application: Ember.inject.controller(),

  buttonSpacingList: [
    {name: i18n.t('minimal', "Minimal (1px)"), id: "minimal"},
    {name: i18n.t('extra_small', "Extra-Small (2px)"), id: "extra-small"},
    {name: i18n.t('small', "Small (5px)"), id: "small"},
    {name: i18n.t('medium', "Medium (10px)"), id: "medium"},
    {name: i18n.t('large', "Large (20px)"), id: "large"},
    {name: i18n.t('huge', "Huge (45px)"), id: "huge"},
    {name: i18n.t('none', "None"), id: "none"}
  ],
  buttonBorderList: [
    {name: i18n.t('none', "None"), id: "none"},
    {name: i18n.t('small', "Small (1px)"), id: "small"},
    {name: i18n.t('medium', "Medium (2px)"), id: "medium"},
    {name: i18n.t('thick', "Thick (5px)"), id: "large"},
    {name: i18n.t('huge', "Huge (10px)"), id: "huge"}
  ],
  buttonTextList: [
    {name: i18n.t('small', "Small (14px)"), id: "small"},
    {name: i18n.t('medium', "Medium (18px)"), id: "medium"},
    {name: i18n.t('large', "Large (22px)"), id: "large"},
    {name: i18n.t('huge', "Huge (35px)"), id: "huge"}
  ],
  buttonTextPositionList: [
    {name: i18n.t('no_text', "No Text (Images Only)"), id: "none"},
    {name: i18n.t('on_top', "Text Above Images"), id: "top"},
    {name: i18n.t('on_bottom', "Text Below Images"), id: "bottom"},
    {name: i18n.t('text_only', "Text Only (No Images)"), id: "text_only"}
  ],
  hiddenButtonsList: [
    {name: i18n.t('show_grid', "Show Grid Lines"), id: "grid"},
    {name: i18n.t('show_dim', "Show as Dimmed Out"), id: "hint"},
    {name: i18n.t('hide_complete', "Hide Completely"), id: "hide"}
  ],
  buttonStyleList: [
    {name: i18n.t('default_font', "Default Font"), id: "default"},
    {name: i18n.t('default_font_caps', "Default Font, All Uppercase"), id: "default_caps"},
    {name: i18n.t('default_font_small', "Default Font, All Lowercase"), id: "default_small"},
    // Don't hate on me, Comic Sans is not my fave, but it's the only web safe font I could find
    // that had the handwritten "a", which could be important for emergent readers.
    {name: i18n.t('comic_sans', "Comic Sans"), id: "comic_sans"},
    {name: i18n.t('comic_sans_caps', "Comic Sans, All Uppercase"), id: "comic_sans_caps"},
    {name: i18n.t('comic_sans_small', "Comic Sans, All Lowercase"), id: "comic_sans_small"},
    {name: i18n.t('open_dyslexic', "OpenDyslexic"), id: "open_dyslexic"},
    {name: i18n.t('open_dyslexic_caps', "OpenDyslexic, All Uppercase"), id: "open_dyslexic_caps"},
    {name: i18n.t('open_dyslexic_small', "OpenDyslexic, All Lowercase"), id: "open_dyslexic_small"},
    {name: i18n.t('architects_daughter', "Architect's Daughter"), id: "architects_daughter"},
    {name: i18n.t('architects_daughter_caps', "Architect's Daughter, All Uppercase"), id: "architects_daughter_caps"},
    {name: i18n.t('architects_daughter_small', "Architect's Daughter, All Lowercase"), id: "architects_daughter_small"},
  ],
  text_sample_class: function() {
    var res = "text_sample ";
    var style = Button.style(this.get('model.preferences.device.button_style'));
    if(style.upper) {
      res = res + "upper ";
    } else if(style.lower) {
      res = res + "lower ";
    }
    if(style.font_class) {
      res = res + style.font_class + " ";
    }
    return res;
  }.property('model.preferences.device.button_style'),
  activationLocationList: [
    {name: i18n.t('pointer_release', "Where I Release My Pointer"), id: "end"},
    {name: i18n.t('pointer_start', "Where I First Press"), id: "start"}
  ],
  buttonSpaceList: [
    {name: i18n.t('dont_stretch', "Don't Stretch Buttons"), id: "none"},
    {name: i18n.t('prefer_tall', "Stretch Buttons, Taller First"), id: "prefer_tall"},
    {name: i18n.t('prefer_tall', "Stretch Buttons, Wider First"), id: "prefer_wide"},
  ],
  buttonBackgroundList: [
    {name: i18n.t('white', "White"), id: "white"},
    {name: i18n.t('black', "Black"), id: "black"}
  ],
  dashboardViewList: [
    {name: i18n.t('communicator', "Communicator View"), id: 'communicator'},
    {name: i18n.t('supporter', "Therapist/Parent/Supporter View"), id: 'supporter'}
  ],
  scanningModeList: [
    {name: i18n.t('row_based', "Row-Based Scanning"), id: "row"},
    {name: i18n.t('column_based', "Column-Based Scanning"), id: "column"},
    {name: i18n.t('button_based', "Button-Based Scanning"), id: "button"},
    {name: i18n.t('region_based', "Region-Based Scanning"), id: "region"}
  ],
  dwellList: [
    {name: i18n.t('eye_gaze', "Eye Gaze Tracking"), id: 'eyegaze'},
    {name: i18n.t('mouse_dwell', "Cursor-Based Dwell Tracking"), id: 'mouse_dwell'}
  ],
  dwellReleaseDistanceList: [
    {name: i18n.t('small', "Small (10px)"), id: 10},
    {name: i18n.t('medium', "Medium (30px)"), id: 30},
    {name: i18n.t('large', "Large (50px)"), id: 50}
  ],
  targetingList: [
    {name: i18n.t('spinning_pie', "Spinning-Pie Animation"), id: 'pie'},
    {name: i18n.t('shrinking_dot', "Shrinking-Dot Animation"), id: 'shrink'}
  ],
  scan_pseudo_options: [
    {name: i18n.t('select', "Select"), id: "select"},
    {name: i18n.t('next', "Next"), id: "next"}
  ],
  vocalizationHeightList: [
    {name: i18n.t('tiny', "Tiny (50px)"), id: "tiny"},
    {name: i18n.t('small', "Small (70px)"), id: "small"},
    {name: i18n.t('medium', "Medium (100px)"), id: "medium"},
    {name: i18n.t('large', "Large (150px)"), id: "large"},
    {name: i18n.t('huge', "Huge (200px)"), id: "huge"}
  ],
  title: function() {
    return "Preferences for " + this.get('model.user_name');
  }.property('model.user_name'),
  check_core_words: function() {
    var _this = this;
    _this.set('core_lists', {loading: true});
    persistence.ajax('/api/v1/users/' + this.get('model.id') + '/core_lists', {type: 'GET'}).then(function(res) {
      _this.set('core_lists', res);
      _this.set('model.core_lists', res);
    }, function(err) {
      _this.set('core_lists', {error: true});
    });
  },
  check_voices_available: function() {
    var _this = this;
    if(capabilities.installed_app) {
      capabilities.tts.status().then(function() {
        _this.set('more_voices_available', true);
      }, function() {
        _this.set('more_voices_available', false);
      });
    } else {
      _this.set('more_voices_available', false);
    }
  },
  non_communicator: function() {
    return this.get('model.preferences.role') != 'communicator';
  }.property('model.preferences.role'),
  region_scanning: function() {
    return this.get('model.preferences.device.scanning_mode') == 'region';
  }.property('model.preferences.device.scanning_mode'),
  select_keycode_string: function() {
    if(this.get('model.preferences.device.scanning_select_keycode')) {
      return (i18n.key_string(this.get('model.preferences.device.scanning_select_keycode')) || 'unknown') + ' key';
    } else {
      return "";
    }
  }.property('model.preferences.device.scanning_select_keycode'),
  next_keycode_string: function() {
    if(this.get('model.preferences.device.scanning_next_keycode')) {
      return (i18n.key_string(this.get('model.preferences.device.scanning_next_keycode')) || 'unknown') + ' key';
    } else {
      return "";
    }
  }.property('model.preferences.device.scanning_next_keycode'),
  fullscreen_capable: function() {
    return capabilities.fullscreen_capable();
  }.property(),
  eyegaze_or_dwell_capable: function() {
    return capabilities.eye_gaze.available || buttonTracker.mouse_used;
  }.property(),
  eyegaze_type: function() {
    return this.get('model.preferences.device.dwell') && this.get('model.preferences.device.dwell_type') == 'eyegaze';
  }.property('model.preferences.device.dwell', 'model.preferences.device.dwell_type'),
  wakelock_capable: function() {
    return capabilities.wakelock_capable();
  }.property(),
  user_voice_list: function() {
    var list = this.get('application.voiceList');
    var result = [];
    var premium_voice_ids = (this.get('model.premium_voices.claimed') || []).map(function(id) { return "extra:" + id; });
    list.forEach(function(voice) {
      if(voice.voiceURI && voice.voiceURI.match(/^extra/)) {
        if(premium_voice_ids.indexOf(voice.voiceURI) >= 0) {
          result.push(voice);
        }
      } else {
        result.push(voice);
      }
    });
    if(result.length > 1) {
      result.push({
        id: 'force_default',
        name: i18n.t('system_default_voice', 'System Default Voice')
      });
      result.unshift({
        id: 'default',
        name: i18n.t('select_a_voice', '[ Select A Voice ]')
      });
    }
    // this is a weird hack because the the voice uri needs to be set *after* the
    // voice list is generated in order to make sure the correct default is selected
    var val = this.get('model.preferences.device.voice.voice_uri');
    this.set('model.preferences.device.voice.voice_uri', 'tmp_needs_changing');
    var _this = this;
    Ember.run.later(function() {
      _this.set('model.preferences.device.voice.voice_uri', val);
    });
    return result;
  }.property('application.voiceList', 'model.premium_voices.claimed', 'model.preferences.device.voice.voice_uris'),
  active_sidebar_options: function() {
    var res = this.get('model.preferences.sidebar_boards');
    if(!res || res.length === 0) {
     res = [].concat(window.user_preferences.any_user.default_sidebar_boards);
    }
    res.forEach(function(b, idx) { b.idx = idx; });
    return res;
  }.property('model.preferences.sidebar_boards'),
  disabled_sidebar_options: function() {
    var defaults = window.user_preferences.any_user.default_sidebar_boards;
    if(this.get('include_prior_sidebar_buttons')) {
      (this.get('model.preferences.prior_sidebar_boards') || []).forEach(function(b) {
        if(!defaults.find(function(o) { return (o.key && o.key == b.key) || (o.alert && b.alert); })) {
          defaults.push(b);
        }
      });
    }
    var active = this.get('active_sidebar_options');
    var res = [];
    defaults.forEach(function(d) {
      if(!active.find(function(o) { return (o.key && o.key == d.key) || (o.alert && d.alert); })) {
        res.push(d);
      }
    });
    return res;
  }.property('model.preferences.sidebar_boards', 'include_prior_sidebar_buttons', 'model.preferences.prior_sidebar_boards'),
  disabled_sidebar_options_or_prior_sidebar_boards: function() {
    return (this.get('disabled_sidebar_options') || []).length > 0 || (this.get('model.preferences.prior_sidebar_boards') || []).length > 0;
  }.property('disabled_sidebar_options', 'model.preferences.prior_sidebar_boards'),
  needs: 'application',
  actions: {
    plus_minus: function(direction, attribute) {
      var default_value = 1.0;
      var step = 0.1;
      var max = 10;
      var min = 0.1;
      var empty_on_default = false;
      if(attribute.match(/volume/)) {
        max = 2.0;
      } else if(attribute.match(/pitch/)) {
        max = 2.0;
      } else if(attribute == 'model.preferences.activation_cutoff') {
        min = 0;
        max = 5000;
        step = 100;
        default_value = 0;
        empty_on_default = true;
      } else if(attribute == 'model.preferences.activation_minimum') {
        min = 0;
        max = 5000;
        step = 100;
        default_value = 0;
        empty_on_default = true;
      } else if(attribute == 'model.preferences.device.eyegaze_dwell') {
        min = 0;
        max = 5000;
        step = 100;
        default_value = 1000;
        empty_on_default = true;
      } else if(attribute == 'model.preferences.device.eyegaze_delay') {
        min = 0;
        max = 5000;
        step = 100;
        default_value = 100;
        empty_on_default = true;
      } else if(attribute == 'model.preferences.board_jump_delay') {
        min = 100;
        max = 5000;
        step = 100;
        default_value = 500;
      } else if(attribute == 'model.preferences.device.scanning_interval') {
        min = 0;
        max = 5000;
        step = 100;
        default_value = 1000;
      } else if(attribute == 'model.preferences.device.scanning_region_columns' || attribute == 'model.preferences.device.scanning_region_rows') {
        min = 1;
        max = 10;
        step = 1;
      }
      var value = parseFloat(this.get(attribute), 10) || default_value;
      if(direction == 'minus') {
        value = value - step;
      } else {
        value = value + step;
      }
      value = Math.round(Math.min(Math.max(min, value), max) * 100) / 100;
      if(value == default_value && empty_on_default) {
        value = "";
      }
      this.set(attribute, value);
    },
    savePreferences: function() {
      // TODO: add a "save pending..." status somewhere
      // TODO: this same code is in utterance.js...
      var pitch = parseFloat(this.get('model.preferences.device.voice.pitch'));
      if(isNaN(pitch)) { pitch = 1.0; }
      var volume = parseFloat(this.get('model.preferences.device.voice.volume'));
      if(isNaN(volume)) { volume = 1.0; }
      this.set('model.preferences.device.voice.pitch', pitch);
      this.set('model.preferences.device.voice.volume', volume);

      var user = this.get('model');
      user.set('preferences.progress.preferences_edited', true);
      var _this = this;
      user.save().then(function(user) {
        if(user.get('id') == app_state.get('currentUser.id')) {
          app_state.set('currentUser', user);
        }
        _this.transitionToRoute('user', user.get('user_name'));
      }, function() { });
    },
    cancelSave: function() {
      this.set('advanced', false);
      var user = this.get('model');
      user.rollbackAttributes();
      this.transitionToRoute('user', user.get('user_name'));
    },
    sidebar_button_settings: function(button) {
      modal.open('sidebar-button-settings', {button: button});
    },
    include_prior_sidebar_buttons: function() {
      this.set('include_prior_sidebar_buttons', true);
    },
    move_sidebar_button: function(button, direction) {
      var active = this.get('active_sidebar_options');
      var disabled = this.get('disabled_sidebar_options');
      if(direction == 'up') {
        var pre = active.slice(0, Math.max(0, button.idx - 1));
        var swap = [button];
        if(active[button.idx - 1]) {
          swap.push(active[button.idx - 1]);
        }
        var post = active.slice(button.idx + 1);
        this.set('model.preferences.sidebar_boards', pre.concat(swap, post));
      } else if(direction == 'down') {
        var pre = active.slice(0, Math.max(0, button.idx));
        var swap = [button];
        if(active[button.idx + 1]) {
          swap.unshift(active[button.idx + 1]);
        }
        var post = active.slice(button.idx + 2);
        this.set('model.preferences.sidebar_boards', pre.concat(swap, post));
      } else if(direction == 'delete') {
        var pre = active.slice(0, button.idx);
        var post = active.slice(button.idx + 1);
        var prior = [].concat(this.get('model.preferences.prior_sidebar_boards') || []);
        prior.push(button);
        prior = prior.uniq(function(o) { return o.alert ? 'alert' : o.key; });
        this.set('model.preferences.prior_sidebar_boards', prior);
        this.set('model.preferences.sidebar_boards', pre.concat(post));
      } else if(direction == 'restore') {
        this.set('model.preferences.sidebar_boards', active.concat([button]));
      }
    },
    test_dwell: function() {
      this.set('testing_dwell', !this.get('testing_dwell'));
    },
    premium_voices: function() {
      var _this = this;
      modal.open('premium-voices', {user: _this.get('model')});
    },
    test_voice: function(which) {
      if(which == 'alternate') {
        utterance.test_voice(this.get('model.preferences.device.alternate_voice.voice_uri'), this.get('model.preferences.device.alternate_voice.rate'), this.get('model.preferences.device.alternate_voice.pitch'), this.get('model.preferences.device.alternate_voice.volume'));
      } else {
        utterance.test_voice(this.get('model.preferences.device.voice.voice_uri'), this.get('model.preferences.device.voice.rate'), this.get('model.preferences.device.voice.pitch'), this.get('model.preferences.device.voice.volume'));
      }
    },
    delete_logs: function() {
      modal.open('confirm-delete-logs', {user: this.get('model')});
    },
    toggle_advanced: function() {
      this.set('advanced', !this.get('advanced'));
    },
    modify_core: function() {
      var _this = this;
      modal.open('modify-core-words', {user: this.get('model')}).then(function() {
        _this.check_core_words();
      });
    },

    grid_event: function(action, row, col) {
      this.send(action, row, col);
    },
    grid_plus_minus: function(direction, attribute) {
      var value = parseInt(this.get(attribute), 10);
      if(direction == 'minus') {
        value = value - 1;
      } else {
        value = value + 1;
      }
      value = Math.min(Math.max(1, value), 20);
      this.set(attribute, value);
    },
    hoverGrid: function(row, col) {
      this.set('previewRows', row);
      this.set('previewColumns', col);
    },
    hoverOffGrid: function() {
      this.set('previewRows', this.get('model.grid.rows'));
      this.set('previewColumns', this.get('dmodel.grid.columns'));
    },
    setGrid: function(row, col) {
      this.set('model.grid.rows', row);
      this.set('model.grid.columns', col);
    }
  }

});
