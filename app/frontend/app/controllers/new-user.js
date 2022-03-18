import CoughDrop from '../app';
import RSVP from 'rsvp';
import modal from '../utils/modal';
import i18n from '../utils/i18n';
import app_state from '../utils/app_state';
import { computed } from '@ember/object';

export default modal.ModalController.extend({
  opening: function() {
    var user = CoughDrop.store.createRecord('user', {
      preferences: {
        registration_type: 'manually-added-org-user'
        
      },
      authored_organization_id: this.get('model.organization_id'),
      org_management_action: 'add_manager'
    });
    this.set('external_device', null);
    this.set('external_vocab', null);
    this.set('external_vocab_size', null);
    this.set('linking', false);
    this.set('error', null);
    user.set('watch_user_name_and_cookies', true);
    this.set('model.user', user);
    this.set('model.user.org_management_action', this.get('model.default_org_management_action'));
  },
  user_types: computed('model.no_licenses', 'model.no_supervisor_licenses', 'model.no_eval_licenses', function() {
    var res = [];
    res.push({id: '', name: i18n.t('select_user_type', "[ Add This User As ]")});
    if(this.get('model.no_licenses')) {
      res.push({id: 'add_user', disabled: true, name: i18n.t('add_sponsored_used', "Add this User As a Sponsored Communicator")});
      if(this.get('model.user.org_management_action') == 'add_user') {
        this.set_unsponsored_action();
      }
    } else {
      res.push({id: 'add_user', name: i18n.t('add_sponsored_used', "Add this User As a Sponsored Communicator")});
    }
    res.push({id: 'add_unsponsored_user', name: i18n.t('add_unsponsored_used', "Add this User As an Unsponsored Communicator")});
    if(this.get('model.premium')) {
      res.push({id: 'add_external_user', name: i18n.t('add_third_party_user', "Add this User As an Third-Party App Communicator")});
    }
    if(this.get('model.no_supervisor_licenses')) {
      res.push({id: 'add_premium_supervisor', disabled: true, name: i18n.t('add_as_premium_supervisor', "Add this User As a Premium Supervisor")});
      if(this.get('model.user.org_management_action') == 'add_premium_supervisor') {
        this.set_unsponsored_action('supervisor');
      }
    } else {
      res.push({id: 'add_premium_supervisor', name: i18n.t('add_as_premium_supervisor', "Add this User As a Premium Supervisor")});
    }
    res.push({id: 'add_supervisor', name: i18n.t('add_as_supervisor', "Add this User As a Supervisor")});
    res.push({id: 'add_manager', name: i18n.t('add_as_manager', "Add this User As a Full Manager")});
    res.push({id: 'add_assistant', name: i18n.t('add_as_assistant', "Add this User As a Management Assistant")});
    if(this.get('model.no_eval_licenses')) {
      res.push({id: 'add_eval', disabled: true, name: i18n.t('add_paid_eval', "Add this User As a Paid Eval Account")});
      if(this.get('model.user.org_management_action') == 'add_eval') {
        this.set_unsponsored_action();
      }
    } else {
      res.push({id: 'add_eval', name: i18n.t('add_paid_eval', "Add this User As a Paid Eval Account")});
    }
    return res;
  }),
  locale_list: computed(function() {
    var list = i18n.get('locales');
    var res = [{name: i18n.t('english_default', "English (default)"), id: 'en'}];
    for(var key in list) {
      if(!key.match(/-|_/)) {
        var str = /* i18n.locales_localized[key] ||*/ i18n.locales[key] || key;
        res.push({name: str, id: key});
      }
    }
    return res;
  }),
  third_party_new_user: computed('model.user.org_management_action', function() {
    return this.get('model.user.org_management_action') == 'add_external_user';
  }),
  communicator_new_user: computed('model.user.org_management_action', function() {
    return this.get('model.user.org_management_action') == 'add_user' || this.get('model.user.org_management_action') == 'add_unsponsored_user';
  }),
  device_options: computed(function() {
    return [].concat(CoughDrop.User.devices).concat({id: 'other', name: i18n.t('other', "Other")});
  }),
  vocab_options: computed('external_device', function() {
    var str = this.get('external_device');
    var device = CoughDrop.User.devices.find(function(d) { return d.name == str; });
    var res = [];
    if(device && device.vocabs && device.vocabs.length > 0) {
      res = res.concat(device.vocabs);
    }
    return res.concat([{id: 'custom', name: i18n.t('custom_vocab', "Custom Vocabulary")}]);
  }),
  set_unsponsored_action(type) {
    if(type == 'supervisor') {
      this.set('model.user.org_management_action', 'add_supervisor');      
    } else {
      this.set('model.user.org_management_action', 'add_unsponsored_user');
    }
  },
  linking_or_exists: computed('linking', 'model.user.user_name_check.exists', function() {
    return this.get('linking') || this.get('model.user.user_name_check.exists');
  }),
  actions: {
    set_device: function(device) {
      this.set('external_device', device.name);
    },
    set_vocab: function(vocab) {
      this.set('external_vocab', vocab.name);
      if(vocab.buttons) {
        this.set('external_vocab_size', vocab.buttons);
      }
    },
    add: function() {
      var controller = this;
      controller.set('linking', true);
      var user = this.get('model.user');
      if(!user.get('user_name') || user.get('user_name').length < 2) {
        return;
      }

      if(this.get('external_device')) {
        var str = this.get('external_device');
        var device = {device_name: this.get('external_device')};
        var found_device = CoughDrop.User.devices.find(function(d) { return d.name == str; });
        if(found_device) {
          device.device_id = found_device.id;
        }
        if(this.get('external_vocab')) {
          var str = this.get('external_vocab');
          device.vocab_name = str;
          var vocabs = (found_device || {vocabs: []}).vocabs || [];
          var vocab = vocabs.find(function(v) { return v.name == str; });
          if(vocab) {
            device.vocab_id = vocab.id;
          }
        }
        if(this.get('external_vocab_size')) {
          device.size = parseInt(this.get('external_vocab_size'), 10);
          if(!device.size) { delete device['size']; }
        }
        user.set('external_device', device);
      }

      user.set('watch_user_name_and_cookies', false);

      if(this.get('third_party_new_user') && this.get('external_device.name')) {
        var dev = this.get('external_device');
        dev.vocab_id = this.get('external_vocab.id');
        dev.vocab = this.get('external_vocab.name');
        dev.vocab_size = parseInt(this.get('external_vocab_size'), 10) || null;
        user.set('external_device', dev);
      }
      var get_user_name = user.save().then(function(user) {
        return user.get('user_name');
      }, function() {
        return RSVP.reject(i18n.t('creating_user_failed', "Failed to create a new user with the given settings"));
      });

      var action = user.get('org_management_action');
      get_user_name.then(function(user_name) {
        var user = controller.get('model.user');
        user.set('org_management_action', action);
        modal.close({
          created: true,
          user: user
        });
      }, function(err) {
          controller.set('linking', false);
          controller.set('error', err);
      });
    }
  }
});
