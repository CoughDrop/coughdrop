import Ember from 'ember';
import app_state from '../utils/app_state';
import speecher from '../utils/speecher';
import modal from '../utils/modal';
import capabilities from '../utils/capabilities';

// ApplicationRouteMixin.reopen({
//   actions: {
//     sessionAuthenticationSucceeded: function() {
//       if(capabilities.installed_app) {
//         location.href = '#/';
//         location.reload();
//       } else {
//         location.href = '/';
//       }
//     },
//     sessionInvalidationSucceeded: function() {
//       if(capabilities.installed_app) {
//         location.href = '#/';
//         location.reload();
//       } else {
//         location.href = '/';
//       }
//     }
//   }
// });
export default Ember.Route.extend({
  setupController: function(controller) {
    app_state.setup_controller(this, controller);
    speecher.refresh_voices();
    controller.set('speecher', speecher);
  },
  actions: {
    willTransition: function(transition) {
      app_state.global_transition(transition);
    },
    didTransition: function() {
      app_state.finish_global_transition();
      Ember.run.later(function() {
        speecher.load_beep().then(null, function() { });
      }, 100);
    },
    speakOptions: function() {
      var last_closed = modal.get('speak_menu_last_closed');
      if(last_closed && last_closed > Date.now() - 500) {
        return;
      }
      modal.open('speak-menu');
    },
    newBoard: function() {
      modal.open('new-board-creation-method');
    },
    pickWhichHome: function() {
      modal.open('which-home');
    },
    confirmDeleteBoard: function() {
      modal.open('confirm-delete-board', {board: this.get('controller.board.model')});
    }
  }
});
