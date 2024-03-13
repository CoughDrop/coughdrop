import Controller from '@ember/controller';
import CoughDrop from '../../app';
import modal from '../../utils/modal';
import Utils from '../../utils/misc';
import i18n from '../../utils/i18n';
import $ from 'jquery';
import app_state from '../../utils/app_state';
import persistence from '../../utils/persistence';
import { observer } from '@ember/object';
import { computed } from '@ember/object';

export default Controller.extend({
  registration_types: CoughDrop.registrationTypes,
  allow_shares_options: [
    {name: i18n.t('email_shares', "Email Me When People I Supervise Share a Message with Me"), id: 'email'},
    {name: i18n.t('text_shares', "Text Me When People I Supervise Share a Message with Me"), id: 'text'},
    {name: i18n.t('app_shares', "Show In the App When People I Supervise Share a Message with Me"), id: 'app'}
  ],
  notification_frequency_options: [
    {name: i18n.t('no_notifications', "Don't Email Me Communicator Reports"), id: ''},
    {name: i18n.t('weekly_notifications', "Email Me Weekly Communicator Reports"), id: '1_week'},
    {name: i18n.t('bi_weekly_reports', "Email Me Communicator Reports Every Two Weeks"), id: '2_weeks'},
    {name: i18n.t('monthly_reports', "Email Me Monthly Communicator Reports"), id: '1_month'}
  ],
  goal_notification_options: [
    {name: i18n.t('email_goal_completion', "Email Me When Goals are Completed or Badges are Earned"), id: 'enabled'},
    {name: i18n.t('dont_email_goal_completion', "Don't Email Me When Goals are Completed or Badges are Earned"), id: 'disabled'}
  ],
  title: computed('model.user_name', function() {
    return "Edit " + this.get('model.user_name');
  }),
  valet_user_name: computed('model.id', function() {
    if(this.get('model.id')) {
      return "model@" + this.get('model.id').replace(/_/, '.')
    } else {
      return "";
    }
  }),
  set_external_device: observer('model.external_device', function() {
    this.set('allow_external_device', !!this.get('model.external_device'));
    this.set('external_device', this.get('model.external_device.device_name'));
    this.set('external_vocab', this.get('model.external_device.vocab_name'));
    this.set('external_vocab_size', this.get('model.external_device.size'));
    this.set('external_access_method', this.get('model.external_device.access_method'));
  }),
  access_methods: computed(function() {
    return [
      {name: i18n.t('touch', "Touch"), id: 'touch'},
      {name: i18n.t('partner_assisted_scanning', "Partner-Assisted Scanning"), id: 'partner_scanning'},
      {name: i18n.t('auditory_or_visual_scanning', "Auditory/Visual Scanning"), id: 'scanning'},
      {name: i18n.t('head_tracking', "Head Tracking"), id: 'head'},
      {name: i18n.t('eye_gaze_tracking', "Eye Gaze Tracking"), id: 'gaze'},
      {name: i18n.t('other', "Other"), id: 'other'},
    ];
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
  load_webhooks: function() {
    var _this = this;
    _this.set('webhooks', {loading: true});
    Utils.all_pages('webhook', {user_id: this.get('model.id')}, function(partial) {
    }).then(function(res) {
      _this.set('webhooks', res);
    }, function(err) {
      _this.set('webhooks', {error: true});
    });
  },
  tools: computed('model.integrations', function() {
    if(this.get('model.integrations') && this.get('model.integrations').length > 0) {
      return this.get('model.integrations').filter(function(i) { return i.get('icon_url'); });
    } else {
      return null;
    }
  }),
  load_integrations: observer('model.id', function(reload) {
    var _this = this;
    this.get('model').check_integrations(reload);
    this.set('status_2fa', null);
  }),
  actions: {
    update_2fa: function(action) {
      var _this = this;
      var uri = _this.get('status_2fa.uri');
      _this.set('status_2fa', {loading: true, uri: uri});
      var opts = {action_2fa: action};
      if(action == 'confirm') {
        opts.code_2fa = _this.get('code_2fa');
      }
      persistence.ajax('/api/v1/users/' + _this.get('model.id') + '/2fa', {
        type: 'POST',
        data: opts
      }).then(function(res) {
        if(res.uri) {
          _this.set('code_2fa', '');
          _this.set('status_2fa', {uri: res.uri});
        } else {
          _this.set('status_2fa', {success: true});
        }
      }, function(err) {
        _this.set('status_2fa', {error: true, uri: uri});
      });
    },
    pick_avatar: function() {
      var _this = this;
      modal.open('pick-avatar', {user: this.get('model')}).then(function(res) {
        if(res && res.image_url) {
          _this.set('model.avatar_url', res.image_url);
        }
      });
    },
    generate_qr: function() {
      this.send('saveProfile', 'qr');
    },
    enable_change_password: function() {
      this.set('change_password', true);
    },
    set_device: function(device) {
      this.set('external_device', device.name);
    },
    set_vocab: function(vocab) {
      this.set('external_vocab', vocab.name);
      if(vocab.buttons) {
        this.set('external_vocab_size', vocab.buttons);
      }
    },
    saveProfile: function(action) {
      // TODO: add a "save pending..." status somewhere
      var user = this.get('model');
      user.set('preferences.progress.profile_edited', true);
      var _this = this;
      if(user.get('password') && user.get('password').length < 6) {
        modal.error(i18n.t('short_password_warning', "Password must be at least 6 characters long"));
        return;
      } else if(user.get('valet_login') && (user.get('valet_password') || '').length > 0 && (user.get('valet_password') || '').length < 6) {
        modal.error(i18n.t('short_valet_password', "Valet Password must be at least 6 characters long"));
        return;
      } else if(user.get('valet_login') && !user.get('valet_password_set') && (user.get('valet_password') || '').length == 0) {
        modal.error(i18n.t('valet_password_required', "Valet Password must be set to enable valet login"));
        return;
      }
      if(user.get('supporter_role') && user.get('valet_login')) {
        user.set('valet_long_term', true);
        user.set('valet_prevent_disable', true);
      }
      if(this.get('allow_external_device')) {
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
        if(this.get('external_access_method')) {
          device.access_method = this.get('external_access_method');
        }
        user.set('external_device', device);
      } else {
        user.set('external_device', false);
      }
      user.save().then(function(user) {
        user.set('password', null);
        user.set('valet_password', null);
        if(action == 'qr') {
          modal.open('modals/valet-mode', {user: user});
        } else {
          _this.transitionToRoute('user', user.get('user_name'));
        }
      }, function(err) {
        if(err.responseJSON && err.responseJSON.errors && err.responseJSON.errors[0] == "incorrect current password") {
          modal.error(i18n.t('incorrect_password', "Incorrect current password"));
        }
        else if (err.errors&& err.errors[0].email_error) {
          modal.error(i18n.t("email_is_already_in_use", "email is already exists."));
        }
        else {
          modal.error(i18n.t('save_failed', "Save failed."));
        }
      });
    },
    cancelSave: function() {
      var user = this.get('model');
      user.rollbackAttributes();
      this.transitionToRoute('user', user.get('user_name'));
    },
    manage_connections: function() {
      this.set('managing_connections', !this.get('managing_connections'));
      if(this.get('managing_connections')) {
        this.load_webhooks();
      }
    },
    add_webhook: function() {
      var _this = this;
      modal.open('add-webhook', {user: this.get('model')}).then(function(res) {
        if(res && res.created) {
          _this.load_webhooks();
        }
      });
    },
    delete_webhook: function(webhook) {
      var _this = this;
      modal.open('confirm-delete-webhook', {user: this.get('model'), webhook: webhook}).then(function(res) {
        if(res && res.deleted) {
          _this.load_integrations(true);
          _this.load_webhooks();
        }
      });
    },
    test_webhook: function(webhook) {
      modal.open('test-webhook', {user: this.get('model'), webhook: webhook});
    },
    add_integration: function() {
      var _this = this;
      modal.open('add-integration', {user: this.get('model')}).then(function(res) {
        if(res && res.created) {
          _this.load_integrations(true);
          _this.load_webhooks();
        }
      });
    },
    browse_tools: function(tool) {
      var _this = this;
      modal.open('add-tool', {user: this.get('model'), tool: tool}).then(function(res) {
        if(res && res.added) {
          _this.load_integrations(true);
          _this.load_webhooks();
        }
      });
    },
    integration_details: function(integration) {
      modal.open('integration-details', {integration: integration, user: this.get('model')});
    },
    delete_integration: function(integration) {
      var _this = this;
      modal.open('confirm-delete-integration', {user: this.get('model'), integration: integration}).then(function(res) {
        if(res && res.deleted) {
          _this.load_integrations(true);
          _this.load_webhooks();
        }
      });
    },
    delete_user: function() {
      modal.open('modals/confirm-delete-user', {user: this.get('model')});
    },
    set_picture: function() {
      var _this = this;
      modal.open('pick-avatar', {user: {}}).then(function(res) {
        if(res && res.image_url) {
          _this.set('contact_image_url', res.image_url);
          _this.send('add_contact');
        }
      });
    },
    message_link: function(contact) {
      var u = CoughDrop.store.createRecord('utterance', {
        button_list: [{'label': "You can use this link to message me!"}], 
        sentence: "You can use this link to message me!",
        timestamp: (new Date()).getTime() / 1000,
        private_only: true,
        user_id: this.get('model.id')
      });
      var user = {
        user_name: contact.name,
        avatar_url: contact.image_url,
        id: this.get('model.id') + 'x' + contact.hash
      }
      var _this = this;
      u.save().then(function(u) {
        modal.open('confirm-notify-user', {user: user, private_only: true, sharer: _this.get('model'), raw: u.get('button_list'), sentence: u.get('sentence'), utterance: u});
      }, function() {
        modal.error(i18n.t('error_creating_utterance', "There was an unexpected error generating the message"));
      });
  
    },
    add_contact: function() {
      var fallback_url = "https://d18vdu4p71yql0.cloudfront.net/libraries/noun-project/Person-1361bc9acf.svg";
      if(this.get('contact_name') && this.get('contact_contact')) {
        var contact = {};
        contact.contact = this.get('contact_contact');
        contact.name = this.get('contact_name');
        contact.image_url = this.get('contact_image_url') || fallback_url;
        contact.contact_type = contact.contact.match(/@/) ? 'email' : 'sms';
        contact.temporary = true;
        if(contact.contact_type == 'email') { 
          contact.email = contact.contact; 
        } else {
          contact.cell_phone = contact.contact;
        }
        var actions = this.get('model.offline_actions') || [];
        actions.push({action: 'add_contact', value: contact});
        this.set('model.offline_actions', actions);
        var contacts = [].concat(this.get('model.contacts') || []);
        var hash = Math.random().toString + (new Date()).getTime();
        contact.hash = hash;
        contacts.push(contact);
        this.set('model.contacts', contacts);
        this.set('contact_name', null);
        this.set('contact_contact', null);
        this.set('contact_image_url', null);
      }
    },
    remove_contact: function(contact) {
      var contacts = [].concat(this.get('model.contacts') || []);
      contacts = contacts.filter(function(c) { return c.hash != contact.hash; });
      this.set('model.contacts', contacts);
      var actions = this.get('model.offline_actions') || [];
      actions.push({action: 'remove_contact', value: contact.hash});
      this.set('model.offline_actions', actions);
    }
  }
});
