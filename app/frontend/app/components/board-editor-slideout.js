import Ember from 'ember';
import InboundActions from '../../ember-component-inbound-actions/inbound-actions';

export default Ember.Component.extend(InboundActions, {
  slideoutService: Ember.inject.service('slideout-service'),
  init: function() {
    this._super();
    this.set('slideout', null); // This will eventually hold our slideout.
    this.set('doRearrangeButtons', false);
  },
  // Set up slideout element once the DOM has been built and elements are accessible.
  didInsertElement: function() {
    this._super();
    var self = this;
    // Create slideout that will move the board over when opened during editing mode.
    var newSlideout = new window.Slideout({
      'panel': Ember.$('#slideout-main-panel')[0],
      'menu': Ember.$('#menu')[0],
      'padding': 256,
      'tolerance': 70
    });

    // Append this to the component.
    this.set('slideout', newSlideout);

    // Set the content of the slideout to appear below the header.
    // When in edit-mode, the header is 70px wide.
    // TODO: make this a constant, or dynamically decide based on just the
    // edit header.
    Ember.$('#menu').css('padding-top', '70px');

    // Set addButton action on enter keypress for input
    Ember.$('#add-word-input').keypress(function(e) {
      var code = (e.keyCode ? e.keyCode : e.which);
      if(code == 13) {
        e.stopPropagation();
        self.actions.addButton(e.target.value, self);
      }
    });
  },
  // Open/close the slideout.
  toggleSlideout: function() {
    this.get('slideout').toggle();
  },
  // Handle subscription to the toggle-slideout-service
  subscribeToService: Ember.on('init', function() {
    this.get('slideoutService').on('toggleSlideout', this,  this.toggleSlideout);
  }),
  unsubscribeToService: Ember.on('willDestroyElement', function () {
    this.get('slideoutService').off('toggleSlideout', this, this.toggleSlideout);
  }),
  actions: {
    // When the remove x button is clicked in the slideout, send an event
    // to the board to clear the given button.
    //
    // TODO: not only clear the button, but also remove it and shift over
    // the other existing buttons.
    removeButton: function(button) {
      this.get('slideoutService').emitRemoveButton(button.id);
    },
    // Add the given label to a button upon enter key press of input.
    // Reset input box to empty upon submission of label.
    addButton: function(buttonLabel, self) {
      self.get('slideoutService').emitAddButton(buttonLabel);
      Ember.$('#add-word-input').val('');
    },
    // Set whether buttons should be rearranged upon edit, based on
    // user's selection.
    setRearrangePreference: function(preference) {
      this.set('doRearrangeButtons', preference);
      this.get('slideoutService').emitNewRearrangePreference(preference);
    }
  }
});
