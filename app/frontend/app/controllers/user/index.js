import Controller from '@ember/controller';
import EmberObject from '@ember/object';
import { set as emberSet, get as emberGet } from '@ember/object';
import { later as runLater } from '@ember/runloop';
import persistence from '../../utils/persistence';
import CoughDrop from '../../app';
import modal from '../../utils/modal';
import app_state from '../../utils/app_state';
import i18n from '../../utils/i18n';
import progress_tracker from '../../utils/progress_tracker';
import Subscription from '../../utils/subscription';
import { observer } from '@ember/object';
import { computed } from '@ember/object';
import { htmlSafe } from '@ember/string';
import session from '../../utils/session';

export default Controller.extend({
  title: computed('model.user_name', function() {
    return "Profile for " + this.get('model.user_name');
  }),
  sync_able: computed('extras.ready', function() {
    return this.get('extras.ready');
  }),
  needs_sync: computed('persistence.last_sync_at', function() {
    var now = (new Date()).getTime();
    return (now - persistence.get('last_sync_at')) > (7 * 24 * 60 * 60 * 1000);
  }),
  check_daily_use: observer('model.user_name', 'model.permissions.admin_support_actions', function() {
    var current_user_name = this.get('daily_use.user_name');
    if((this.get('model.user_name') && current_user_name != this.get('model.user_name') && this.get('model.permissions.admin_support_actions')) || !this.get('daily_use')) {
      var _this = this;
      _this.set('daily_use', {loading: true});
      persistence.ajax('/api/v1/users/' + this.get('model.user_name') + '/daily_use', {type: 'GET'}).then(function(data) {
        var log = CoughDrop.store.push({ data: {
          id: data.log.id,
          type: 'log',
          attributes: data.log
        }});
        _this.set('daily_use', log);
      }, function(err) {
        if(err && err.result && err.result.error == 'no data available') {
          _this.set('daily_use', null);
        } else {
          _this.set('daily_use', {error: true});
        }
      });
    }
  }),
  blank_slate: computed(
    'model.preferences.home_board.key',
    'public_boards_shortened',
    'private_boards_shortened',
    'root_boards_shortened',
    'starred_boards_shortened',
    'shared_boards_shortened',
    function() {
      return !this.get('model.preferences.home_board.key') &&
        (this.get('public_boards_shortened') || []).length === 0 &&
        (this.get('private_boards_shortened') || []).length === 0 &&
        (this.get('root_boards_shortened') || []).length === 0 &&
        (this.get('starred_boards_shortened') || []).length === 0 &&
        (this.get('shared_boards_shortened') || []).length === 0;
    }
  ),
  filter_board_list: observer(
    'board_list.filtered_results',
    'filtered_results',
    'filterString',
    'show_all_boards',
    function() {
      if(this.get('filterString')) {
        if(!this.get('show_all_boards')) {
          this.set_show_all_boards();
        } else {
          var re = new RegExp(this.get('filterString'), 'i');
          (this.get('filtered_results') || this.get('board_list.filtered_results') || []).forEach(function(i) {
            var matches = i.board.get('search_string').match(re) || i.children.find(function(c)  { return c.board.get('search_string').match(re); }); 
            emberSet(i, 'hidden', !matches);
          });  
        }
      } else {
        (this.get('filtered_results') || this.get('board_list.filtered_results') || []).forEach(function(i) {
          emberSet(i, 'hidden', false);
        });
      }
    }
  ),
  board_list: computed(
    'selected',
    'parent_object',
    'show_all_boards',
    // 'filterString',
    'model.id',
    'model.my_boards',
    'model.prior_home_boards',
    'model.public_boards',
    'model.private_boards',
    'model.root_boards',
    'model.starred_boards',
    'model.shared_boards',
    'model.tagged_boards',
    'model.my_boards.length',
    'model.prior_home_boards.length',
    'model.public_boards.length',
    'model.private_boards.length',
    'model.root_boards.length',
    'model.starred_boards.length',
    'model.shared_boards.length',
    function() {
      var list = [];
      var res = {remove_type: 'delete', remove_label: i18n.t('delete_lower', "delete"), remove_icon: 'glyphicon glyphicon-trash'};
      var cluster_orphans = false;
      if(this.get('selected') == 'mine' || !this.get('selected')) {
        list = this.get('model.my_boards');
        cluster_orphans = true;
      } else if(this.get('selected') == 'public') {
        list = this.get('model.public_boards');
      } else if(this.get('selected') == 'private') {
        list = this.get('model.private_boards');
      } else if(this.get('selected') == 'root') {
        list = this.get('model.root_boards');
      } else if(this.get('selected') == 'starred') {
        list = this.get('model.starred_boards');
        res.remove_type = 'unstar';
        res.remove_label = i18n.t('unstar', "un-like");
        res.remove_icon = 'glyphicon glyphicon-star-empty';
      } else if(this.get('selected') == 'shared') {
        list = this.get('model.shared_boards');
        res.remove_type = 'unlink';
        res.remove_label = i18n.t('unlink', "unlink");
        res.remove_icon = 'glyphicon glyphicon-remove';
      } else if(this.get('selected') == 'tagged') {
        list = this.get('model.tagged_boards');
        res.remove_type = 'untag';
        res.remove_label = i18n.t('unlink', "unlink");
        res.remove_icon = 'glyphicon glyphicon-remove';
      } else if(this.get('selected') == 'prior_home') {
        list = this.get('model.prior_home_boards');
      }
      list = list || [];
      if(list.loading || list.error) { return list; }

      if(this.get('parent_object')) {
        list = [];
        list.push({board: this.get('parent_object.board')});
        (this.get('parent_object.children') || []).forEach(function(b) {
          list.push({board: b.board});
        });
        list.done = true;
        res.sub_result = true;
      }

      res.results = list;
      var board_ids = {};
      var new_list = [];
      var _this = this;
      if(this.get('parent_object')) {
        list.forEach(function(ref) {
          if(ref.board.id == _this.get('parent_object.board.id')) {
            ref.str = "a " + ref.board.name;
          } else {
            ref.str = "b" + (parseInt(ref.board.name, 10) || 0).toString().padStart(6, '0') + ' ' + ref.board.name.toLowerCase();
          }
        });
        new_list = list.sort(function(a, b) { return a.str.localeCompare(b.str); });
      } else {
        var copies = {};
        var roots = [];
        var shallow_roots = {};
        list.forEach(function(b) {
          if(emberGet(b, 'id').match(/-/) && (!emberGet(b, 'copy_id') || emberGet(b, 'copy_id') == emberGet(b, 'id') || emberGet(b, 'copy_id') == emberGet(b, 'id').split(/-/)[0])) {
            var user_id = emberGet(b, 'id').split(/-/)[1];
            if(user_id == _this.get('model.id')) {
              shallow_roots[emberGet(b, 'copy_id') || emberGet(b, 'id').split(/-/)[0]] = b;
            }
          }
        });
        list.forEach(function(b) {
          if(emberGet(b, 'id').match(/-/) && emberGet(b, 'id').split(/-/)[1] == _this.get('model.id') && emberGet(b, 'copy_id') && shallow_roots[emberGet(b, 'copy_id')]) {
            // Shallow clones are a little trickier to get added as sub-boards to their root
            var shallow = shallow_roots[emberGet(b, 'copy_id')];
            copies[emberGet(shallow, 'id')] = copies[emberGet(shallow, 'id')] || [];
            copies[emberGet(shallow, 'id')].push(b);
          } else if(emberGet(b, 'copy_id') && emberGet(b, 'copy_id') != emberGet(b, 'id')) {
            var copy_id = emberGet(b, 'copy_id');
            copies[copy_id] = copies[copy_id] || [];
            copies[copy_id].push(b);
          } else {
            roots.push(b);
          }
        });
        roots.forEach(function(b) {
          var obj = {board: b, children: []};
          var id = emberGet(b, 'id');
          if(copies[id]) {
            copies[id].forEach(function(c) { obj.children.push({board: c})});
            delete copies[id];
          }
          new_list.push(obj);
          // board_ids[emberGet(b, 'id')] = obj;
          // if(emberGet(b, 'copy_id') && board_ids[b.get('copy_id')]) {
          //   board_ids[b.get('copy_id')].children.push({board: b});
          // } else {
          //   new_list.push(obj);
          // }
        });
        new_list.forEach(function(ref) {
          if(ref.board && ref.board.sort_score != null) {
            ref.str = (99999999 - ref.board.sort_score).toString().padStart(8, '0') + ' ';
            ref.str = ref.str + (parseInt(ref.board.name, 10) || 0).toString().padStart(6, '0') + ' ';
            ref.str = ref.str + ref.board.name;
          } else {
            ref.str = "99999999 " + (ref.board || {}).name;
          }
        });
        new_list = new_list.sort(function(a, b) { return a.str.localeCompare(b.str); });
        // TODO: sort this list on something better than just id
        for(var id in copies) {
          if(cluster_orphans) {
            var obj = {
              board: CoughDrop.store.createRecord('board', {name: "Orphan Boards id:" + id}),
              children: [],
              orphan: true
            };
            copies[id].forEach(function(c) { obj.children.push({board: c})});
            new_list.push(obj);  
          } else {
            copies[id].forEach(function(c) {
              new_list.push({board: c, children: []});
            });
          }
        }
        // list.forEach(function(b) {
        //   var obj = {board: b, children: []};
        //   board_ids[emberGet(b, 'id')] = obj;
        //   if(emberGet(b, 'copy_id') && board_ids[b.get('copy_id')]) {
        //     board_ids[b.get('copy_id')].children.push({board: b});
        //   } else {
        //     new_list.push(obj);
        //   }
        // });
      }
      /* if(this.get('filterString')) {
        var re = new RegExp(this.get('filterString'), 'i');
        new_list = new_list.filter(function(i) { 
          return i.board.get('search_string').match(re) || i.children.find(function(c)  { return c.board.get('search_string').match(re); }); 
        });
        res.filtered_results = new_list.slice(0, 18);
      } else */ if(this.get('show_all_boards')) {
        res.filtered_results = new_list.slice(0, 300);
      } else {
        if(list.done && new_list && new_list.length <= 18) {
          this.set_show_all_boards();
        }
        res.filtered_results = new_list.slice(0, 18);
      }
      res.filtered_results_key = res.filtered_results.map(function(b) { return (b.id || b.board.id) + (b.children || []).length; }).join(',');
      return res;
    }
  ),
  update_filtered_results: observer('board_list.filtered_results_key', function() {
    var last_key = this.get('last_filtered_results_key');
    if(last_key != this.get('board_list.filtered_results_key')) {
      this.set('last_filtered_results_key', this.get('board_list.filtered_results_key'));
      this.set('filtered_results', this.get('board_list.filtered_results'));       
    }
  }),
  set_show_all_boards: function() {
    this.set('show_all_boards', true);
  },
  reload_logs: observer('persistence.online', function() {
    var _this = this;
    if(!persistence.get('online')) { return; }
    if(!(_this.get('model.logs') || {}).length) {
      if(this.get('model')) {
        this.set('model.logs', {loading: true});
      }
    }
    this.store.query('log', {user_id: this.get('model.id'), per_page: 4}).then(function(logs) {
      if(_this.get('model')) {
        _this.set('model.logs', logs.slice(0,4));
      }
    }, function() {
      if(!(_this.get('model.logs') || {}).length) {
        if(_this.get('model')) {
          _this.set('model.logs', {error: true});
        }
      }
    });
  }),
  load_badges: observer('model.permissions', function() {
    if(this.get('model.permissions')) {
      var _this = this;
      if(!(_this.get('model.badges') || {}).length) {
        _this.set('model.badges', {loading: true});
      }
      this.store.query('badge', {user_id: this.get('model.id'), earned: true, per_page: 4}).then(function(badges) {
        _this.set('model.badges', badges);
      }, function(err) {
        if(!(_this.get('model.badges') || {}).length) {
          _this.set('model.badges', {error: true});
        }
      });
    }
  }),
  load_goals: observer('model.permissions', function() {
    if(this.get('model.permissions')) {
      var _this = this;
      if(!(_this.get('model.goals') || {}).length) {
        _this.set('model.goals', {loading: true});
      }
      this.store.query('goal', {user_id: this.get('model.id'), per_page: 3}).then(function(goals) {
        _this.set('model.goals', goals.map(function(i) { return i; }).filter(function(g) { return g.get('active'); }));
      }, function(err) {
        if(!(_this.get('model.goals') || {}).length) {
          _this.set('model.goals', {error: true});
        }
      });
    }
  }),
  subscription: computed(
    'model.permissions.admin_support_actions',
    'model.subscription',
    function() {
      if(this.get('model.permissions.admin_support_actions') && this.get('model.subscription')) {
        var sub = Subscription.create({user: this.get('model')});
        sub.reset();
        return sub;
      }
    }
  ),
  generate_or_append_to_list: function(args, list_name, list_id, append) {
    var _this = this;
    if(list_id != _this.get('list_id')) { return; }
    var prior = _this.get(list_name) || [];
    if(prior.error || prior.loading) { prior = []; }
    if(!append && !prior.length) {
      _this.set(list_name, {loading: true});
    }
    _this.store.query('board', args).then(function(boards) {
      if(_this.get('list_id') == list_id) {
        if(!append && prior.length) {
          prior = [];
        }

        prior.pushObjects(boards.map(function(i) { return i; }));
//        var result = prior.concat(boards.map(function(i) { return i; }));
        prior.user_id = _this.get('model.id');
        _this.set(list_name, prior);
        var meta = persistence.meta('board', boards); //_this.store.metadataFor('board');
        if(meta && meta.more) {
          args.per_page = meta.per_page;
          args.offset = meta.next_offset;
          _this.generate_or_append_to_list(args, list_name, list_id, true);
        } else {
          _this.set(list_name + '.done', true);
        }
      }
    }, function() {
      if(_this.get('list_id') == list_id && !prior.length) {
        _this.set(list_name, {error: true});
      }
    });
  },
  raw_daily_use: computed('daily_use.daily_use_history', function() {
    var div = document.createElement('div');
    (this.get('daily_use.daily_use_history') || []).forEach(function(day) {
      var sub = document.createElement('div');
      sub.setAttribute('class', day.activity);
      sub.setAttribute('style', day.display_style);
      var span = document.createElement('span');
      span.innerText = day.date;
      sub.appendChild(span);
      div.appendChild(sub);
    })
    return htmlSafe(div.innerHTML);
  }),
  filtered_devices: computed('model.devices', function() {
    return (this.get('model.devices') || []).slice(0, 10);
  }),
  more_label: computed(
    'selected',
    'current_tag',
    'other_selected',
    function() {
      if(this.get('other_selected')) {
        var sel = this.get('selected');
        if(sel == 'shared') {
          return i18n.t('shared', "Shared with Me");
        } else if(sel == 'prior_home') {
          return i18n.t('prior_home', "Prior Home Boards");
        } else if(sel == 'private') {
          return i18n.t('private', "Private");
        } else if(sel == 'tagged') {
          return this.get('current_tag');
        } else {
          return i18n.t('other', "Other");
        }
      } else {
        return i18n.t('more_ellipsis', "More...");

      }
    }
  ),
  update_home_board: observer('model.preferences.home_board.key', function() {
    if(this.get('model.preferences.home_board.key')) {
      if(this.get('home_board_pref.key') != this.get('model.preferences.home_board.key')) {
        this.set('home_board_pref', this.get('model.preferences.home_board'));
      }
      var _this = this;
      CoughDrop.store.findRecord('board', this.get('model.preferences.home_board.key')).then(function(brd) {
        _this.set('home_board_pref', brd);
      }, function(err) { });
    }
  }),
  update_selected: observer('selected', 'persistence.online', 'current_tag', function() {
    var _this = this;
    var list_id = Math.random().toString();
    this.set('list_id', list_id);
    var model = this.get('model');
    if(!persistence.get('online')) { return; }
    var default_key = null;
    if(!_this.get('selected') && model) {
      default_key = model.get('permissions.supervise') ? 'mine' : 'public';
    }
    this.set('other_selected', this.get('selected') && ['mine', 'public', 'root', 'liked', 'starred'].indexOf(this.get('selected')) == -1);
    ['mine', 'public', 'private', 'starred', 'shared', 'prior_home', 'root', 'tagged'].forEach(function(key, idx) {
      if(_this.get('selected') == key || key == default_key) {
        _this.set(key + '_selected', true);
        if(key == 'mine') {
          _this.generate_or_append_to_list({user_id: model.get('id')}, 'model.my_boards', list_id);
        } else if(key == 'public') {
          _this.generate_or_append_to_list({user_id: model.get('id'), public: true}, 'model.public_boards', list_id);
        } else if(key == 'private') {
          _this.generate_or_append_to_list({user_id: model.get('id'), private: true}, 'model.private_boards', list_id);
        } else if(key == 'root') {
          _this.generate_or_append_to_list({user_id: model.get('id'), root: true, sort: 'home_popularity'}, 'model.root_boards', list_id);
        } else if(key == 'starred') {
          if(model.get('permissions.supervise')) {
            _this.generate_or_append_to_list({user_id: model.get('id'), starred: true}, 'model.starred_boards', list_id);
          } else {
            _this.generate_or_append_to_list({user_id: model.get('id'), public: true, starred: true}, 'model.starred_boards', list_id);
          }
        } else if(key == 'tagged') {
          _this.generate_or_append_to_list({user_id: model.get('id'), tag: _this.get('current_tag'), sort: 'home_popularity'}, 'model.tagged_boards', list_id);
        } else if(key == 'shared') {
          _this.generate_or_append_to_list({user_id: model.get('id'), shared: true}, 'model.shared_boards', list_id);
        }
      } else {
        _this.set(key + '_selected', false);
      }
    });

    if(model && model.get('permissions.edit')) {
      if(!model.get('preferences.home_board.key')) {
        _this.generate_or_append_to_list({user_id: app_state.get('domain_board_user_name'), starred: true, public: true}, 'model.starting_boards', list_id);
      }
    }
  }),
  external_device_or_no_home: computed('model.external_device', 'model.preference.home_board', function() {
    return this.get('model.external_device') || this.get('model.preferences.home_board');
  }),
  actions: {
    sync: function() {
      console.debug('syncing because manually triggered');
      persistence.sync(this.get('model.id'), 'all_reload').then(null, function() { });
    },
    setup: function() {
      if(window.ga) {
        window.ga('send', 'event', 'Setup', 'start', 'Setup started');
      }
      app_state.set('auto_setup', false);
      this.transitionToRoute('setup', {queryParams: {page: null, user_id: this.get('model.id')}});
    },
    quick_assessment: function() {
      var _this = this;
      app_state.check_for_currently_premium(_this.get('model', 'quick_assessment')).then(function() {
        modal.open('quick-assessment', {user: _this.get('model')}).then(function() {
          _this.reload_logs();
        });
      }, function() { });
    },
    stats: function() {
      this.transitionToRoute('user.stats', this.get('model.user_name'));
    },
    approve_or_reject_org: function(approve) {
      var user = this.get('model');
      var type = this.get('edit_permission') ? 'add_edit' : 'add';
      if(approve == 'user_approve') {
        user.set('supervisor_key', "approve-org");
      } else if(approve == 'user_reject') {
        user.set('supervisor_key', "remove_supervisor-org");
      } else if(approve == 'supervisor_approve') {
        var org_id = this.get('model.pending_supervision_org.id');
        user.set('supervisor_key', "approve_supervision-" + org_id);
      } else if(approve == 'supervisor_reject') {
        var org_id = this.get('model.pending_supervision_org.id');
        user.set('supervisor_key', "remove_supervision-" + org_id);
      }
      user.save().then(function() {

      }, function() { });
    },
    add_supervisor: function() {
      var _this = this;
      app_state.check_for_currently_premium(this.get('model'), 'add_supervisor', true).then(function() {
        modal.open('add-supervisor', {user: _this.get('model')});
      }, function() { });
    },
    view_devices: function() {
      modal.open('device-settings', this.get('model'));
    },
    masquerade: function() {
      var user_id = this.get('model.id');
      if(this.get('model.permissions.support_actions')) {
        modal.open('modals/masquerade', {user: this.get('model')});
      }
    },
    run_eval: function() {
      var _this = this;
      app_state.check_for_currently_premium(_this.get('model'), 'eval', false, true).then(function() {
        app_state.set_speak_mode_user(_this.get('model.id'), false, false, 'obf/eval');
      });
    },
    remote_model: function(user) {
      var _this = this;
      app_state.check_for_currently_premium(_this.get('model'), 'eval', false, true).then(function() {
        modal.open('modals/remote-model', {user_id: _this.get('model.id')});
      });
    },
    eval_settings: function() {
      modal.open('modals/eval-status', {user: this.get('model')});
    },
    supervision_settings: function() {
      modal.open('supervision-settings', {user: this.get('model')});
    },
    show_more_boards: function() {
      this.set('show_all_boards', true);
    },
    set_selected: function(selected) {
      this.set('selected', selected);
      this.set('show_all_boards', false);
      this.set('parent_object', null);
//       this.set('filterString', '');
    },
    set_tag: function(tag) {
      this.set('selected', 'tagged');
      this.set('show_all_boards', false);
      this.set('parent_object', null);
      this.set('current_tag', tag);
    },
    load_children: function(obj) {
      this.set('show_all_boards', false);
      if(obj) {
        this.set('prior_filter_string', this.get('filterString') || '');
        this.set('filterString', '');  
      } else {
        this.set('filterString', this.get('prior_filter_string') || '');  
        this.set('prior_filter_string', '');
      }
      this.set('parent_object', obj);
    },
    nothing: function() {
    },
    badge_popup: function(badge) {
      modal.open('badge-awarded', {badge: badge, user_id: this.get('model.id')});
    },
    remove_board: function(action, board) {
      var _this = this;
      if(action == 'delete') {
        modal.open('confirm-delete-board', {board: board, redirect: false}).then(function(res) {
          if(res && res.update) {
            _this.update_selected();
          }
        });
      } else if(action == 'delete_orphans') {
        board.name = board.board.name;
        modal.open('confirm-delete-board', {board: board, redirect: false, orphans: true}).then(function(res) {
          if(res && res.update) {
            _this.update_selected();
          }
        });
      } else {
        modal.open('confirm-remove-board', {action: action, tag: _this.get('current_tag'), board: board, user: this.get('model')}).then(function(res) {
          if(res && res.update) {
            _this.update_selected();
          }
        });
      }
    },
    resendConfirmation: function() {
      persistence.ajax('/api/v1/users/' + this.get('model.user_name') + '/confirm_registration', {
        type: 'POST',
        data: {
          resend: true
        }
      }).then(function(res) {
        modal.success(i18n.t('confirmation_resent', "Confirmation email sent, please check your spam box if you can't find it!"));
      }, function() {
        modal.error(i18n.t('confirmation_resend_failed', "There was an unexpected error requesting a confirmation email."));
      });
    },
    set_subscription: function(action) {
      if(action == 'cancel') {
        this.set('subscription_settings', null);
      } else if(action == 'confirm' && this.get('subscription_settings')) {
        this.set('subscription_settings.loading', true);
        var _this = this;
        persistence.ajax('/api/v1/users/' + this.get('model.user_name') + '/subscription', {
          type: 'POST',
          data: {
            type: this.get('subscription_settings.action')
          }
        }).then(function(data) {
          progress_tracker.track(data.progress, function(event) {
            if(event.status == 'errored') {
              _this.set('subscription_settings.loading', false);
              _this.set('subscription_settings.error', i18n.t('subscription_error', "There was an error checking status on the users's subscription"));
            } else if(event.status == 'finished') {
              _this.get('model').reload().then(function() {
                _this.get('subscription').reset();
              });
              _this.set('subscription_settings', null);
              modal.success(i18n.t('subscription_updated', "User purchase information updated!"));
            }
          });
        }, function() {
          _this.set('subscription_settings.loading', false);
          _this.set('subscription_settings.error', i18n.t('subscription_update_error', "There was an error updating the users's account information"));
        });
      } else if(action == 'eval') {
        this.set('subscription_settings', {action: action, type: i18n.t('eval_device', "Evaluation Device")});
      } else if(action == 'never_expires') {
        this.set('subscription_settings', {action: action, type: i18n.t('never_expires', "Never Expiring Subscription")});
      } else if(action == 'manual_supporter') {
        this.set('subscription_settings', {action: action, type: i18n.t('manual_supporter', "Manually Set as Supporter")});
      } else if(action == 'manual_modeler') {
        this.set('subscription_settings', {action: action, type: i18n.t('manual_modeler', "Manually Set as Modeler")});
      } else if(action == 'add_1') {
        this.set('subscription_settings', {action: action, type: i18n.t('add_one_month_to_expiration', "Add 1 Month to Expiration")});
      } else if(action == 'add_5_years') {
        this.set('subscription_settings', {action: action, type: i18n.t('add_five_years_to_expiration', "Add 5 Years to Expiration")});
      } else if(action == 'communicator_trial') {
        this.set('subscription_settings', {action: action, type: i18n.t('communicator_trial', "Manually Set as Communicator Free Trial")});
      } else if(action == 'add_voice') {
        this.set('subscription_settings', {action: action, type: i18n.t('add_1_premium_voice', "Add 1 Premium Voice")});
      } else if(action == 'enable_extras') {
        this.set('subscription_settings', {action: action, type: i18n.t('enable_extras', "Enable Premium Symbols Access")});
      } else if(action == 'supporter_credit') {
        this.set('subscription_settings', {action: action, type: i18n.t('add_premium_supporter_credit', "Add 1 Premium Supporter Credit")});
      } else if(action == 'check_remote') {
        this.set('subscription_settings', {action: action, type: i18n.t('recheck_purchasing_status', "Re-Check Purchasing Status")});
      } else if(action == 'restore_purchase') {
        this.set('subscription_settings', {action: action, type: i18n.t('restore_purchase', "Restore an Accidentally-Disabled Purchase")});
      } else if(action == 'force_logout') {
        this.set('subscription_settings', {action: action, type: i18n.t('force_device_logout', "Force Logout on all Devices (this may cause the user to lose some logs)")});
      }
    },
    rename_user: function(confirm) {
      if(confirm === undefined) {
        this.set('new_user_name', {});
      } else if(confirm === false) {
        this.set('new_user_name', null);
      } else {
        if(!this.get('new_user_name')) {
          this.set('new_user_name', {});
        }
        if(!this.get('new_user_name.value')) { return; }

        var _this = this;
        var new_key = _this.get('new_user_name.value');
        new_key = CoughDrop.clean_path(new_key);
        var old_key = _this.get('new_user_name.old_value');
        if(old_key != _this.get('model.user_name')) { return; }

        _this.set('new_user_name', {renaming: true});
        persistence.ajax('/api/v1/users/' + this.get('model.id') + '/rename', {
          type: 'POST',
          data: {
            old_key: _this.get('model.user_name'),
            new_key: new_key
          }
        }).then(function(res) {
          _this.set('new_user_name', null);
          _this.transitionToRoute('user.index', res.key);
          runLater(function() {
            modal.success(i18n.t('user_renamed_to', "User successfully renamed to %{k}. The full renaming process can take a little while to complete.", {k: res.key}));
          }, 200);
        }, function(err) {
          _this.set('new_user_name', {error: true});
        });
      }
    },
    reset_password: function(confirm) {
      if(confirm === undefined) {
        this.set('password', {});
      } else if(confirm === false) {
        this.set('password', null);
      } else {
        if(!this.get('password')) {
          this.set('password', {});
        }
        var keys = "23456789abcdef";
        var pw = "";
        for(var idx = 0; idx < 8; idx++) {
          var hit = Math.round(Math.random() * keys.length);
          var key = keys.substring(hit, hit + 1);
          pw = pw + key;
        }
        this.set('password.pw', pw);
        this.set('password.loading', true);
        var _this = this;

        persistence.ajax('/api/v1/users/' + this.get('model.user_name'), {
          type: 'POST',
          data: {
            '_method': 'PUT',
            'reset_token': 'admin',
            'user': {
              'password': pw
            }
          }
        }).then(function(data) {
          _this.set('password.loading', false);
        }, function() {
          _this.set('password.error', true);
        });
      }
    },
    load_starred: function() {
      var opts = {force_board_state: {key: 'obf/stars-' + this.get('model.id')}};
      app_state.home_in_speak_mode(opts);
    },
    external_device: function() {
      if(this.get('model.permissions.edit')) {
        modal.open('modals/external-device', {user: this.get('model')});
      } else {

      }
    },
    manual_log: function() {
      CoughDrop.Log.manual_log(this.get('model.id'), !!this.get('model.external_device'));
    },
    profile_preview: function() {
      modal.open('modals/profiles', {user: this.get('model')});
    }
  }
});
