import Ember from 'ember';
import modal from '../utils/modal';
import app_state from '../utils/app_state';
import i18n from '../utils/i18n';

// Modal to allow the user to decide how they would like to build a board, either:
//    - automatically by topic (the user will receive a suggested board to edit)
//    - manually (the user will start from scratch with an empty board)
//    - by import (the user can import one or multiple boards from obf or csv)
export default modal.ModalController.extend({
  actions: {
    createAutoByTopic: function(event) {
      app_state.set('createBoardMethod', 'auto');
      modal.open('new-board', {createAutomatically: true});
    },
    createManually: function() {
      app_state.set('createBoardMethod', 'manual');
      modal.open('new-board', {createAutomatically: false});
    }
  }
});
