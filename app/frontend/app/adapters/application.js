import Ember from "ember";
import DS from "ember-data";
import persistence from '../utils/persistence';

var res = DS.RESTAdapter.extend({
  namespace: 'api/v1',
  headers: { // This may or may not be necessary.
    // We were having CORS problems, and this might fix it
    'Access-Control-Allow-Origin': '*'
  }
}, persistence.DSExtend);

export default res;
