import Ember from 'ember';
import modal from '../utils/modal';
import CoughDrop from '../app';
import app_state from '../utils/app_state';
import i18n from '../utils/i18n';
import editManager from '../utils/edit_manager';

export default modal.ModalController.extend({
  opening: function(settings) {
    // Create empty board record, and set whether we are creating this board
    // automatically or manually. (Originally set when opening the modal).
    this.set('model', CoughDrop.store.createRecord('board', {public: false, license: {type: 'private'}, grid: {rows: 2, columns: 4}}));
    this.set('model.createAutomatically', settings.createAutomatically);

    if(window.webkitSpeechRecognition) {
      var speech = new window.webkitSpeechRecognition();
      if(speech) {
        speech.continuous = true;
        this.set('speech', {engine: speech});
      }
    }

    var supervisees = [];

    var locale = window.navigator.language.replace(/-/g, '_');
    var pieces = locale.split(/_/);
    if(pieces[0]) { pieces[0] = pieces[0].toLowerCase(); }
    if(pieces[1]) { pieces[1] = pieces[1].toUpperCase(); }
    locale = pieces[0] + "_" + pieces[1];
    var locales = i18n.get('locales');
    if(locales[locale]) {
      this.set('model.locale', locale);
    } else {
      locale = locale.split(/_/)[0];
      if(locales[locale]) {
        this.set('model.locale', locale);
      }
    }

    if(app_state.get('sessionUser.supervisees')) {
      app_state.get('sessionUser.supervisees').forEach(function(supervisee) {
        supervisees.push({
          name: supervisee.user_name,
          image: supervisee.avatar_url,
          disabled: !supervisee.edit_permission,
          id: supervisee.id
        });
      });
      if(supervisees.length > 0) {
        supervisees.unshift({
          name: i18n.t('me', "me"),
          id: 'self',
          image: app_state.get('sessionUser.avatar_url_with_fallback')
        });
      }
      this.set('model.for_user_id', 'self');
    }
    this.set('supervisees', supervisees);
  },
  locales: function() {
    var list = i18n.get('locales');
    var res = [{name: i18n.t('choose_locale', '[Choose a Language]'), id: ''}];
    for(var key in list) {
      res.push({name: list[key], id: key});
    }
    res.push({name: i18n.t('unspecified', "Unspecified"), id: ''});
    return res;
  }.property(),
  ahem: function() {
    console.log(this.get('model.for_user_id'));
  }.observes('model.for_user_id'),
  license_options: CoughDrop.licenseOptions,
  attributable_license_type: function() {
    if(this.get('model.license') && this.get('model.license.type') != 'private') {
      this.set('model.license.author_name', app_state.get('currentUser.name'));
      this.set('model.license.author_url',app_state.get('currentUser.profile_url'));
    }
    return this.get('model.license.type') != 'private';
  }.property('model.license.type'),
  label_count: function() {
    var str = this.get('model.grid.labels') || "";
    var lines = str.split(/\n|,\s*/);
    return lines.filter(function(l) { return l && !l.match(/^\s+$/); }).length;
  }.property('model.grid', 'model.grid.labels'),
  too_many_labels: function() {
    return (this.get('label_count') || 0) > (parseInt(this.get('model.grid.rows'), 10) * parseInt(this.get('model.grid.columns'), 10));
  }.property('label_count', 'model.grid.rows', 'model.grid.columns'),
  labels_class: function() {
    var res = "label_count ";
    if(this.get('too_many_labels')) {
      res = res + "too_many ";
    }
    return res;
  }.property('too_many_labels'),
  speech_enabled: function() {
    return !!this.get('speech');
  }.property('speech'),
  closing: function() {
    this.send('stop_recording');
  },
  actions: {
    grid_event: function(action, row, col) {
      this.send(action, row, col);
    },
    plus_minus: function(direction, attribute) {
      var value = parseInt(this.get(attribute), 10);
      if(direction == 'minus') {
        value = value - 1;
      } else {
        value = value + 1;
      }
      value = Math.min(Math.max(1, value), 20);
      this.set(attribute, value);
    },
    more_options: function() {
      this.set('more_options', true);
    },
    pick_core: function() {
      this.send('stop_recording');
      this.set('core_lists', i18n.get('core_words'));
      this.set('core_words', i18n.core_words_map());
    },
    record_words: function() {
      var speech = this.get('speech');
      var _this = this;
      if(speech && speech.engine) {
        speech.engine.onresult = function(event) {
          var result = event.results[event.resultIndex];
          if(result && result[0] && result[0].transcript) {
            var text = result[0].transcript.replace(/^\s+/, '');
            _this.send('add_recorded_word', text);
          }
        };
        speech.engine.onaudiostart = function(event) {
          if(_this.get('speech')) {
            _this.set('speech.recording', true);
          }
        };
        speech.engine.onend = function(event) {
          console.log("you are done talking");
          if(_this.get('speech') && _this.get('speech.resume')) {
            _this.set('speech.resume', false);
            speech.engine.start();
          }
        };
        speech.engine.onsoundstart = function() {
          console.log('sound!');
        };
        speech.engine.onsoundend = function() {
          console.log('no more sound...');
        };
        speech.engine.start();
        if(this.get('speech')) {
          this.set('speech.almost_recording', true);
          this.set('speech.words', []);
          this.set('core_lists', null);
          this.set('core_words', null);
        }
      }
    },
    stop_recording: function() {
      if(this.get('speech') && this.get('speech.engine')) {
        this.set('speech.resume', false);
        this.get('speech.engine').abort();
      }
      if(this.get('speech')) {
        this.set('speech.recording', false);
        this.set('speech.almost_recording', false);
      }
    },
    next_word: function() {
      if(this.get('speech') && this.get('speech.engine')) {
        var _this = this;
        this.set('speech.resume', true);
        this.get('speech.engine').stop();
      }
    },
    remove_word: function(id) {
      var lines = (this.get('model.grid.labels') || "").split(/\n|,\s*/);
      var words = [].concat(this.get('speech.words') || []);
      var new_words = [];
      var word = {};
      for(var idx = 0; idx < words.length; idx++) {
        if(words[idx].id == id) {
          word = words[idx];
        } else {
          new_words.push(words[idx]);
        }
      }
      var new_lines = [];
      var removed = false;
      for(var idx = 0; idx < lines.length; idx++) {
        if(!lines[idx] || lines[idx].match(/^\s+$/)) {
        } else if(!removed && lines[idx] == word.label) {
          // only remove once I guess
          removed = true;
        } else {
          new_lines.push(lines[idx]);
        }
      }
      if(this.get('speech')) {
        this.set('speech.words', new_words);
        this.set('model.grid.labels', new_lines.join("\n"));
      }
    },
    add_recorded_word: function(str) {
      var lines = (this.get('model.grid.labels') || "").split(/\n|,\s*/);
      var words = [].concat(this.get('speech.words') || []);
      var id = Math.random();
      words.push({id: id, label: str});
      var new_lines = [];
      for(var idx = 0; idx < lines.length; idx++) {
        if(!lines[idx] || lines[idx].match(/^\s+$/)) {
        } else {
          new_lines.push(lines[idx]);
        }
      }
      new_lines.push(str);
      if(this.get('speech')) {
        this.set('speech.words', words);
        this.set('model.grid.labels', new_lines.join("\n"));
      }
    },
    enable_word: function(id) {
      var words = this.get('core_words');
      var enabled_words = [];
      var disable_word = null;
      for(var idx = 0; idx < words.length; idx++) {
        if(words[idx].id == id) {
          if(Ember.get(words[idx], 'active')) {
            Ember.set(words[idx], 'active', false);
            disable_word = words[idx].label;
          } else {
            Ember.set(words[idx], 'active', true);
          }
        }
        if(Ember.get(words[idx], 'active')) {
          enabled_words.push(words[idx].label);
        }
      }
      var lines = (this.get('model.grid.labels') || "").split(/\n|,\s*/);
      var new_lines = [];
      var word_filter = function(w) { return w != lines[idx]; };
      for(var idx = 0; idx < lines.length; idx++) {
        if(disable_word && lines[idx] == disable_word) {
          // only remove once I guess
          disable_word = null;
        } else if(!lines[idx] || lines[idx].match(/^\s+$/)) {
        } else {
          new_lines.push(lines[idx]);
          if(enabled_words.indexOf(lines[idx]) != -1) {
            enabled_words = enabled_words.filter(word_filter);
          }
        }
      }
      for(var idx = 0; idx < enabled_words.length; idx++) {
        new_lines.push(enabled_words[idx]);
      }
      // TODO: one-per-line is long and not terribly readable. maybe make commas the default?
      // in that case it might make sense to invert the button-population algorithm
      // (right now it's vertical-first)
      this.set('model.grid.labels', new_lines.join("\n"));
    },
    saveBoard: function(event) {
      var _this = this;
      if(this.get('model.license')) {
        this.set('model.license.copyright_notice_url', CoughDrop.licenseOptions.license_url(this.get('model.license.type')));
      }
      this.get('model').save().then(function(board) {
        modal.close(true);
        editManager.auto_edit(board.get('id'));
        _this.transitionToRoute('board', board.get('key'));
      });
    },
    hoverGrid: function(row, col) {
      this.set('previewRows', row);
      this.set('previewColumns', col);
    },
    hoverOffGrid: function() {
      this.set('previewRows', this.get('model.grid.rows'));
      this.set('previewColumns', this.get('model.grid.columns'));
    },
    setGrid: function(row, col) {
      this.set('model.grid.rows', row);
      this.set('model.grid.columns', col);
    },
    pickImageUrl: function(url) {
      this.set('model.image_url', url);
    }
  },
  updatePreview: function() {
    this.set('previewRows', this.get('model.grid.rows'));
    this.set('previewColumns', this.get('model.grid.columns'));
  }.observes('model.grid.rows', 'model.grid.columns'),
  updateShow: function() {
    var grid = [];
    var maxRows = 6, maxColumns = 12;
    var previewEnabled = this.get('previewRows') <= maxRows && this.get('previewColumns') <= maxColumns;
    for(var idx = 1; idx <= maxRows; idx++) {
      var row = [];
      for(var jdx = 1; jdx <= maxColumns; jdx++) {
        var preview = (previewEnabled && idx <= this.get('previewRows') && jdx <= this.get('previewColumns'));
        row.push({
          row: idx,
          column: jdx,
          preview: preview,
          preview_class: "cell " + (preview ? "preview" : "")
        });
      }
      grid.push(row);
    }
    this.set('showGrid', grid);
  }.observes('previewRows', 'previewColumns')
});
