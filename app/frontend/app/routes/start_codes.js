import Route from '@ember/routing/route';
import app_state from '../utils/app_state';
import speecher from '../utils/speecher';

export default Route.extend({
  model: function(params) {
    this.set('code', params.id);
  },
  setupController: function(controller) {
    if(controller.get('code') != this.get('code')) {
      controller.set('code', this.get('code'));
      controller.lookup();  
    }
  }
});
