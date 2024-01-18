import modal from '../utils/modal';
import RSVP from 'rsvp';
import BoardHierarchy from '../utils/board_hierarchy';
import { computed } from '@ember/object';
import app_state from '../utils/app_state';
import { later as runLater } from '@ember/runloop';

export default modal.ModalController.extend({
  opening: function() {
    this.set('hierarchy', null);
    if(this.get('model.board') && !this.get('model.orphans')) {
      this.get('model.board').reload();
      var _this = this;
      _this.set('hierarchy', {loading: true});
      BoardHierarchy.load_with_button_set(this.get('model.board'), {deselect_on_different: true, prevent_keyboard: true, prevent_different: true}).then(function(hierarchy) {
        _this.set('hierarchy', hierarchy);
      }, function(err) {
        _this.set('hierarchy', {error: true});
      });
    }
    this.set('delete_downstream', !!this.get('model.orphans'));
  },
  using_user_names: computed('model.board.using_user_names', function() {
    return (this.get('model.board.using_user_names') || []).join(', ');
  }),
  deleting_boards_count: computed('model.orphans', 'model.board', 'hierarchy', function() {
    if(this.get('model.orphans')) {
      return this.get('model.board.children.length');
    }
    var board = this.get('model.board');
    // TODO: this will need to work differently for shallow copies
    var other_board_ids = board.get('downstream_board_ids');
    if(this.get('hierarchy') && this.get('hierarchy').selected_board_ids) {
      other_board_ids = this.get('hierarchy').selected_board_ids();
    }
    return other_board_ids.length;
  }),
  actions: {
    deleteBoard: function(decision) {
      var _this = this;
      var board = this.get('model.board');
      _this.set('model.deleting', {deleting: true});
      var load_promises = [];
      var other_board_ids = [];
      if(this.get('delete_downstream')) {
        if(this.get('model.orphans')) {
          other_board_ids = (this.get('model.board.children') || []).map(function(b) { return b.board; });
        } else {
          other_board_ids = board.get('downstream_board_ids');
          if(this.get('hierarchy') && !this.get('hierarchy.error') && this.get('hierarchy').selected_board_ids) {
            other_board_ids = this.get('hierarchy').selected_board_ids();
          }  
        }  
      }
      var save = RSVP.resolve();
      var deleted_ids = [];
      if(!this.get('model.orphans')) {
        try {
          board.deleteRecord();
          save = board.save();
          deleted_ids.push(board.get('id'));
        } catch(e) {
          // TODO: if on the board page, it may barf when deleting the current board
        }
      }

      var other_defers = [];
      var next_defer = function() {
        var d = other_defers.shift();
        if(d) { d.start_delete(); }
      };
      other_board_ids.forEach(function(id) {
        var defer = RSVP.defer();
        defer.start_delete = function() {
          var find = RSVP.resolve(id);
          if(typeof id == 'string') {
            if(deleted_ids.indexOf(id) == -1) {
              try {
                find = _this.store.findRecord('board', id);
              } catch(e) {
                defer.reject({error: 'find_error', e: e});
                return;
              }
            } else {
              defer.resolve(id);
              return;
            }
          }
          find.then(function(b) {
            if(board.orphan || b.get('user_name') == board.get('user_name')) {
              runLater(function() {
                if(_this.get('model.deleting')) {
                  _this.set('model.deleting', {deleting: true, board_key: b.get('key')});
                }

                b.deleteRecord();
                deleted_ids.push(b.get('id'));
                b.save().then(function() {
                  defer.resolve(b);
                }, function(err) { defer.reject(err); });  
              });
            }
          }, function(err) { defer.reject(err); });  
        };
        defer.promise.then(function() {
          next_defer();
        }, function() {
          next_defer();
        });
        other_defers.push(defer);
      });

      var wait_for_deletes = save.then(function() {
        return RSVP.all_wait(other_defers.map(function(d) { return d.promise; }));
      });

      var concurrent_deletes = 5;
      for(var idx = 0; idx < concurrent_deletes; idx ++) {
        next_defer();
      }

      wait_for_deletes.then(function() {
        if(_this.get('model.redirect')) {
          app_state.return_to_index();
        }
        modal.close({update: true});
      }, function() {
        _this.set('model.deleting', false);
        _this.set('model.error', true);
      });
    }
  }
});
