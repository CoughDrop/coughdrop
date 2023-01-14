import CoughDrop from '../../app';
import modal from '../../utils/modal';
import BoardHierarchy from '../../utils/board_hierarchy';
import i18n from '../../utils/i18n';
import stashes from '../../utils/_stashes';
import app_state from '../../utils/app_state';
import persistence from '../../utils/persistence';
import progress_tracker from '../../utils/progress_tracker';
import { computed, set as emberSet, get as emberGet } from '@ember/object';
import capabilities from '../../utils/capabilities';

export default modal.ModalController.extend({
  opening: function() {
    this.set('status', null);
    this.set('new_start_code', null);
    (this.get('org_or_user.start_codes') || []).forEach(function(code) {
      emberSet(code, 'to_delete', false);
      emberSet(code, 'status', null);
    });
  },
  org_or_user: computed('model.user', 'model.org', function() {
    return this.get('model.user') || this.get('model.org');
  }),
  invalid_code: computed('code', function() {
    return this.get('code') && (this.get('code').length <= 6 || !this.get('code').match(/^[8a-zA-Z]/));
  }),
  sorted_start_codes: computed('org_or_user.start_codes', function() {
    return (this.get('org_or_user.start_codes') || []).sort(function(a, b) {
      if(a.disabled && !b.disabled) {
        return 1;
      } else if(!a.disabled && b.disabled) {
        return -1;
      } else {
        return 0;
      }
    });
  }),
  locales: computed(function() {
    var list = i18n.get('locales');
    var res = [];
    res.push({name: i18n.t('dont_set', "Don't Set a Language"), id: 'none'});
    for(var key in list) {
      res.push({name: list[key], id: key});
    }
    res.push({name: i18n.t('unspecified', "Unspecified"), id: ''});
    return res;
  }),
  symbol_libraries: computed('current_user', function() {
    var list = [];
    list.push({name: i18n.t('dont_set_preferred_symbols', "Don't Set Preferred Symbols"), id: ''});
    list.push({name: i18n.t('use_opensymbols', "Opensymbols.org free symbol libraries"), id: 'opensymbols'});
    list.push({name: i18n.t('use_lessonpix_with_addon', "LessonPix symbol library (requires paid add-on)"), id: 'lessonpix'});
    list.push({name: i18n.t('use_symbolstix_with_addon', "SymbolStix Symbols (requires paid add-on)"), id: 'symbolstix'});
    list.push({name: i18n.t('use_pcs_with_addon', "PCS Symbols by Tobii Dynavox (requires paid add-on)"), id: 'pcs'});  
    list.push({name: i18n.t('use_twemoji', "Emoji icons (authored by Twitter)"), id: 'twemoji'});
    list.push({name: i18n.t('use_noun-project', "The Noun Project black outlines"), id: 'noun-project'});
    list.push({name: i18n.t('use_arasaac', "ARASAAC free symbols"), id: 'arasaac'});
    list.push({name: i18n.t('use_tawasol', "Tawasol symbol library"), id: 'tawasol'});

    return list;
  }),
  actions: {
    new: function() {
      this.set('new_start_code', !this.get('new_start_code'));
    },
    delete: function(code, check) {
      if(check) {
        emberSet(code, 'to_delete', !emberGet(code, 'to_delete'));
      } else if(emberGet(code, 'to_delete')) {
        var _this = this;
        var path = '/api/v1/users/' + _this.get('model.user.id') + '/start_code';
        if(_this.get('model.org')) {
          path = '/api/v1/organizations/' + _this.get('model.org.id') + '/start_code';
        }
        emberSet(code, 'status', {deleting: true});
        persistence.ajax(path, {type: 'POST', data: {
          code: code.code,
          delete: true
        }}).then(function(res) {
          emberSet(code, 'status', null);
          emberSet(code, 'disabled', true);
          _this.get('org_or_user').reload();
        }, function(err) {
          emberSet(code, 'status', {error: true});
        });
      }
    },
    copy: function(code) {
      capabilities.sharing.copy_text(code)
      modal.success(i18n.t('code_copied_to_clipboard', "Code Copied to Clipboard!"));
    },
    generate: function() {
      var _this = this;
      if(_this.get('invalid_code')) { return; }
      var ovr = {};
      if(_this.get('code')) {
        ovr.proposed_code = _this.get('code');
      }
      if(_this.get('locale') && _this.get('locale') != 'none') {
        ovr.locale = _this.get('locale');
      }
      if(_this.get('symbol_library')) {
        ovr.symbol_library = _this.get('symbol_library');
      }
      if(_this.get('premium')) {
        ovr.premium = true;
      }
      if(_this.get('supervisors')) {
        ovr.supervisors = [];
        _this.get('supervisors').split(/\s*,\s*/).forEach(function(s) {
          if(s) { ovr.supervisors.push(s); }
        })
      }
      if(_this.get('home_board_key')) {
        ovr.home_board_key = _this.get('home_board_key');
      }
      var path = '/api/v1/users/' + _this.get('model.user.id') + '/start_code';
      if(_this.get('model.org')) {
        path = '/api/v1/organizations/' + _this.get('model.org.id') + '/start_code';
      }
      if(_this.get('model.user') || _this.get('model.org')) {
        _this.set('status', {generating: true});
        persistence.ajax(path, {type: 'POST', data: {
          overrides: ovr
        }}).then(function(res) {
          _this.set('status', null);
          _this.get('org_or_user').reload();
        }, function(err) {
          _this.set('status', {error: true, taken: err.result && err.result == 'code is taken'});
        });
      }
    }
  }
});
