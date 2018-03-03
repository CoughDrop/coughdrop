/* global require, module */
var EmberApp = require('ember-cli/lib/broccoli/ember-app');

module.exports = function(defaults) {
  var app = new EmberApp(defaults, {
    'ember-cli-babel': {
      includePolyfill:true
    },
    sourcemaps: {
      enabled: false
    },
    storeConfigInMeta: false,
//    vendorFiles: {
//      'handlebars.js': null,
//      'ember.js': 'bower_components/ember/ember.prod.js',
//      'ember-data.js': 'bower_components/ember-data/ember-data.prod.js'
//    },
    fingerprint: {
      enabled: false
    },
    minifyJS: {
      enabled: false
    },
    'ember-cli-babel': {
      includePolyfill: true
    }
  });

  // Use `app.import` to add additional libraries to the generated
  // output files.
  //
  // If you need to use different assets in different
  // environments, specify an object as the first parameter. That
  // object's keys should be the environment name and the values
  // should be the asset to use in that environment.
  //
  // If the library that you are including contains AMD or ES6
  // modules that you would like to import into your application
  // please specify an object with the list of modules as keys
  // along with the exports of each module as its value.
  app.import('bower_components/IndexedDBShim/dist/indexeddbshim.min.js');
  // Hammer-Time causes a weird bug in Windows Chrome where if you
  // tap a dropdown, when you touch (not mouse) the element within the dropdown, it
  // triggers a click event on the page with the page-level coordinates
  // matching the coordinates of the touch relative to the top left corner of
  // the dropdown list. This typically results in a click on the "home"
  // link in the top right corner of the app.
//  app.import('bower_components/hammer-time/hammer-time.js');
  app.import('bower_components/moment/moment.js');
  app.import('bower_components/tinycolor/tinycolor.js');
  app.import('bower_components/jquery-minicolors/jquery.minicolors.min.js');
  app.import('bower_components/bootstrap/dist/js/bootstrap.min.js');
  app.import('bower_components/recordrtc/RecordRTC.min.js');
  app.import('bower_components/wordcloud2.js/src/wordcloud2.js');
  app.import('vendor/media_recorder/media_recorder.js');
  app.import('vendor/speak_js/speakClient.js');
  app.import('vendor/speech/speech.js');

  return app.toTree();
};
