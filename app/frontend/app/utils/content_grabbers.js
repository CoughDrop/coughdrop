import Ember from 'ember';
import EmberObject from '@ember/object';
import { later as runLater, run } from '@ember/runloop';
import {set as emberSet, get as emberGet} from '@ember/object';
import RSVP from 'rsvp';
import $ from 'jquery';
import i18n from './i18n';
import CoughDrop from '../app';
import editManager from './edit_manager';
import persistence from './persistence';
import coughDropExtras from './extras';
import modal from './modal';
import stashes from './_stashes';
import capabilities from './capabilities';
import app_state from './app_state';
import Utils from './misc';
import progress_tracker from './progress_tracker';

var contentGrabbers = EmberObject.extend({
  setup: function(button, controller) {
    this.controller = controller;
    pictureGrabber.setup(button, controller);
    soundGrabber.setup(button, controller);
    boardGrabber.setup(button, controller);
    linkGrabber.setup(button, controller);
  },
  clear: function() {
    pictureGrabber.clear();
    soundGrabber.clear();
    boardGrabber.clear();
    linkGrabber.clear();
  },
  unlink: function() {
    pictureGrabber.controller = null;
    pictureGrabber.button = null;
    soundGrabber.controller = null;
    soundGrabber.button = null;
    soundGrabber.recordings_controller = null;
    boardGrabber.controller = null;
    boardGrabber.button = null;
  },
  save_record: function(object) {
    var _this = this;
    var promise = new RSVP.Promise(function(resolve, reject) {
      if((object.get('url') || "").match(/^data:/)) {
        object.set('data_url', object.get('url'));
        object.set('url', null);
      }
      var original = object;
      var original_url = object.get('url');
      object.save().then(function(object) {
        if(!object.get('url') && object.get('data_url')) {
          object.set('url', object.get('data_url'));
        }
        if(object.get('pending')) {
          var meta = persistence.meta(object.constructor.modelName, null); //object.store.metadataFor(object.constructor.modelName);
          if(!meta || !meta.remote_upload) { return reject({error: 'remote_upload parameters required'}); }
          // upload to S3
          var get_data_url = RSVP.resolve(object.get('data_url'));
          if(!object.get('data_url') && original_url) {
            get_data_url = persistence.ajax('/api/v1/search/proxy?url=' + encodeURIComponent(original_url), { type: 'GET'
            }).then(function(data) {
              return data.data;
            });
          }
          get_data_url.then(function(data_url) {
            meta.remote_upload.data_url = data_url;
            meta.remote_upload.blob = object.get('blob');
            return _this.upload_to_remote(meta.remote_upload).then(function(data) {
              if(data.confirmed) {
                object.set('url', data.url);
                object.set('pending', false);
                resolve(object);
              } else {
                reject({error: "upload not confirmed"});
              }
            }, function(err) {
              reject(err);
            });
          }, function(err) {
            reject(err);
          });
        } else {
          resolve(object);
        }
      }, function(err) { reject({error: "record failed to save", ref: err}); });
    });
    return promise;
  },
  upload_to_remote: function(params) {
    var _this = this;
    var promise = new RSVP.Promise(function(resolve, reject) {
      var fd = new FormData();
      for(var idx in params.upload_params) {
        fd.append(idx, params.upload_params[idx]);
      }
      if(params.blob) {
        fd.append('file', params.blob);
      } else if(params.data_url) {
        fd.append('file', _this.data_uri_to_blob(params.data_url));
      }

      persistence.ajax({
        url: params.upload_url,
        type: 'POST',
        data: fd,
        processData: false,  // tell jQuery not to process the data
        contentType: false   // tell jQuery not to set contentType
      }).then(function(data) {
        var method = params.success_method || 'GET';
        persistence.ajax({
          url: params.success_url,
          type: method
        }).then(function(data) {
          resolve(data);
        }, function(err) {
          reject({error: "upload not completed"});
        });
      }, function(err) {
        reject({error: "upload failed"});
      });
    });
    return promise;
  },
  upload_for_processing: function(file, url, params, progressor) {
    var data_uri = null;

    var generate_data_uri = contentGrabbers.read_file(file);

    var prep = generate_data_uri.then(function(data) {
      data_uri = data.target.result;
      return persistence.ajax(url, {
        type: 'POST',
        data: params
      });
    });

    var upload = prep.then(function(meta) {
      meta.remote_upload.data_url = data_uri;
      meta.remote_upload.success_method = 'POST';
      return contentGrabbers.upload_to_remote(meta.remote_upload);
    });

    var progress = upload.then(function(data) {
      if(data.progress) {
        return new RSVP.Promise(function(resolve, reject) {
          progress_tracker.track(data.progress, function(event) {
            progressor.set('progress', event);
            if(event.status == 'errored') {
              progressor.set('status', {errored: true});
              reject({error: 'processing failed'});
            } else if(event.status == 'finished') {
              progressor.set('status', {finished: true});
              resolve(event.result);
            }
          });
        });
      } else {
        return RSVP.reject({error: 'not confirmed'});
      }
    });

    return progress;
  },
  data_uri_to_blob: function(data_uri) {
    var pre = data_uri.split(/;/)[0];
    var type = pre.split(/:/)[1];
    var binary = atob(data_uri.split(',')[1]);
    var array = [];
    for(var i = 0; i < binary.length; i++) {
        array.push(binary.charCodeAt(i));
    }
    return new Blob([new Uint8Array(array)], {type: type});
  },
  file_dropped: function(id, type, file) {
    this.droppedFile = {
      type: type,
      file: file
    };

    var state = type == 'image' ? 'picture' : 'sound';
    this.board_controller.send('buttonSelect', id, state);
    var _this = this;
    runLater(function() {
      _this.check_for_dropped_file();
    }, 100);
  },
  check_for_dropped_file: function() {
    var drop = this.droppedFile;
    this.droppedFile = null;
    if(drop) {
      if(drop.file.url) {
        pictureGrabber.web_image_dropped(drop);
      } else {
        if(drop.type == 'image') {
          pictureGrabber.file_selected(drop.file);
        } else {
          soundGrabber.file_selected(drop.file);
        }
      }
    }
  },
  file_selected: function(type, files) {
    var image = null, sound = null, board = null, video = null, zip = null;
    for(var idx = 0; idx < files.length; idx++) {
      if(!image && files[idx].type.match(/^image/)) {
        image = files[idx];
      } else if(!sound && files[idx].type.match(/^audio/)) {
        sound = files[idx];
      } else if(!video && files[idx].type.match(/^video/)) {
        video = files[idx];
      } else {
        if(!board && files[idx].name.match(/\.(obf|obz|csv)$/)) {
          board = files[idx];
        }
        if(!zip && files[idx].name.match(/\.zip$/)) {
          zip = files[idx];
        }
      }
    }
    if(type == 'image' || type == 'avatar' || type == 'badge') {
      if(image) {
        pictureGrabber.file_selected(image, type);
      } else {
        alert(i18n.t('no_valid_image_found', "No valid image found"));
      }
    } else if(type == 'sound') {
      if(sound) {
        soundGrabber.file_selected(sound);
      } else {
        alert(i18n.t('no_valid_sound_found', "No valid sound found"));
      }
    } else if(type == 'video') {
      if(video) {
        videoGrabber.file_selected(video);
      } else {
        alert(i18n.t('no_valid_video_found', "No valid video found"));
      }
    } else if(type == 'board') {
      boardGrabber.file_selected(board);
    } else if(type == 'recording') {
      soundGrabber.recording_selected(zip || sound);
    } else {
      alert(i18n.t('bad_file', "bad file"));
    }
  },
  file_pasted: function(type, items) {
    var image = null;
    for(var idx = 0; idx < items.length; idx++) {
      if(!image && items[idx].type.match(/^image/)) {
        image = items[idx];
      }
    }
    if(type == 'image' && image) {
      pictureGrabber.file_selected(image.getAsFile());
    }
  },
  content_dropped: function(button_id, dataTransfer) {
    if(!app_state.get('edit_mode') || !dataTransfer) { return; }
    if(dataTransfer.files && dataTransfer.files.length > 0) {
      var files = dataTransfer.files;
      var image = null, sound = null;
      for(var idx = 0; idx < files.length; idx++) {
        if(!image && files[idx].type.match(/^image/)) {
          image = files[idx];
        } else if(!sound && files[idx].type.match(/^audio/)) {
          sound = files[idx];
        }
      }
      if(image) {
        contentGrabbers.file_dropped(button_id, 'image', image);
      } else if(sound) {
        contentGrabbers.file_dropped(button_id, 'sound', sound);
      } else {
        alert(i18n.t('no_valid_files', "No valid images or sounds found"));
      }
    } else if(dataTransfer.items && dataTransfer.items.length > 0) {
      var found = false;
      var promises = [];
      var results = {};
      var lookup_promise = function(type, item) {
        return new RSVP.Promise(function(res, rej) {
          item.getAsString(function(str) {
            results[type] = str;
            res();
          });
        });
      };
      for(var idx = 0; idx < dataTransfer.types.length; idx++) {
        if(!found && dataTransfer.types[idx] == 'text/uri-list') {
          found = true;
          promises.push(lookup_promise('url', dataTransfer.items[idx]));
        }
        if(dataTransfer.types[idx] == 'text/html') {
          found = true;
          promises.push(lookup_promise('html', dataTransfer.items[idx]));
        }
      }
      RSVP.all_wait(promises).then(function(res) {
        if(results.html) {
          var pieces = results.html.split(/<\s*img/);
          if(pieces.length > 1) {
            var match = pieces[1].match(/src\s*=\s*['"]([^'"]+)/);
            if(match && match[1]) {
              results.url = match[1];
            }
          }
        }
        if(results.url) {
          contentGrabbers.file_dropped(button_id, 'image', {url: results.url});
        }
      });
      if(!found) {
        alert(i18n.t('unrecognized_drop_type', "Unrecognized drop type"));
      }
    } else {
      alert(i18n.t('unrecognized_drop_type', "Unrecognized drop type"));
    }
  },
  read_file: function(file, type) {
    return new RSVP.Promise(function(resolve, reject) {
      var reader = new FileReader();
      var _this = this;
      reader.onloadend = function(data) {
        run(function() {
          if(type == 'blob') {
            var blob = new Blob([new Uint8Array(data.target.result)], { type: file.type });
            resolve(blob);
          } else {
            resolve(data);
          }
        });
      };
      if(type != 'blob') {
        reader.readAsDataURL(file);
      } else {
        reader.readAsArrayBuffer(file);
      }
    });
  },
  save_pending: function() {
    soundGrabber.save_pending();
    var _this = this;
    // the returned promise isn't saying everything is done saving, just that
    // essential information held in an iframe in the settings modal.
    return editManager.get_edited_image().then(function(data) {
      pictureGrabber.edited_image_data = data;
      pictureGrabber.save_pending();
      return {ready: true};
    }, function() {
      pictureGrabber.edited_image_data = null;
      pictureGrabber.save_pending();
      return RSVP.resolve({ready: true});
    });
  },
  capture_types: function() {
    var res = {};
    if(navigator.device && navigator.device.capture && navigator.device.capture.captureAudio) {
      if(capabilities.subsystem != 'Kindle') {
        res.audio = true;
      }
    }
    if(navigator.device && navigator.device.capture && navigator.device.capture.captureImage) {
      res.image = true;
    }
    if(navigator.device && navigator.device.capture && navigator.device.capture.captureVideo) {
      if(capabilities.subsystem != 'Kindle') {
        res.video = true;
      }
    }
    return res;
  },
  file_type_extensions: {
    'image/png': '.png',
    'image/svg+xml': '.svg',
    'image/gif': '.gif',
    'image/icon': '.ico',
    'image/x-icon': '.ico',
    'image/jpeg': '.jpg',
    'image/jpg': '.jpg',
    'image/tiff': '.tif',
    'image/x-tiff': '.tif',
    'audio/mpeg2': '.mp2',
    'audio/mpeg': '.mp3',
    'audio/mp3': '.mp3',
    'audio/midi': '.mid',
    'audio/x-mid': '.mid',
    'audio/x-midi': '.mid',
    'audio/x-mpeg': '.mp2',
    'audio/mpeg3': '.mp3',
    'audio/x-mpeg3': '.mp3',
    'audio/wav': '.wav',
    'audio/x-wav': '.wav',
    'audio/ogg': '.oga',
    'audio/flac': '.flac',
    'audio/webm': '.webm',
    'video/webm': '.webm',
    'video/quicktime': '.mov',
    'video/mp4': '.mp4',
    'video/mpeg4': '.mp4',
    'video/3gpp': '.3gp',
    'video/x-msvideo': '.avi',
    'video/x-ms-wmv': '.wmv'
  }
}).create();
var pictureGrabber = EmberObject.extend({
  setup: function(button, controller) {
    this.controller = controller;
    this.button = button;
    var _this = this;
    runLater(function() {
      button.findContentLocally().then(function() {
        var image = button.get('image');
        if(image) {
          image.check_for_editable_license();
        }
      });
    });
    _this.controller.addObserver('image_preview', _this, _this.default_image_preview_license);
  },
  default_size: 300,
  size_image: function(data_url, stored_size) {
    var _this = this;
    return new RSVP.Promise(function(resolve, reject) {
      if(data_url.match(/^http/)) { return resolve({url: data_url}); }
      else if(data_url.match(/image\/gif/)) { return resolve({url: data_url}); }
      if(!window.scratch_canvas) {
        window.scratch_canvas = document.createElement('canvas');
      }
      window.scratch_canvas.width = stored_size || _this.default_size;
      window.scratch_canvas.height = stored_size || _this.default_size;

      var context = window.scratch_canvas.getContext('2d');
      var img = document.createElement('img');
      var result = null;
      var canvas = window.scratch_canvas;
      img.onload = function() {
        run(function() {
          if(img.width < _this.default_size && img.height < _this.default_size && data_url.match(/^data/)) {
            return resolve({url: data_url, width: img.width, height: img.height});
          }
          var pct = img.width / img.height;
          var width = canvas.width, height = canvas.height, x = 0, y = 0;
          // TODO: is it actually good to have them all square? some button dimensions
          // would actually prefer non-square buttons if possible...
          if(pct > 1.0) {
            var diff = canvas.height - (canvas.height / pct);
            y = diff / 2.0;
            height = canvas.height - diff;
          } else {
            var diff = canvas.width - (canvas.width * pct);
            x = diff / 2.0;
            width = canvas.width - diff;
          }
          context.clearRect(0, 0, canvas.width, canvas.height);
          context.drawImage(img, x, y, width, height);
          try {
            result = canvas.toDataURL();
          } catch(e) { }
          if(result) {
            resolve({url: result, width: canvas.width, height: canvas.height});
          } else {
            resolve({url: data_url});
          }
        });
      };
      img.onready = img.onload;
      img.onerror = function() {
        run(function() {
          resolve({url: data_url});
        });
      };
      img.src = data_url;
      if(img.width) {
        img.onload();
      }
    });
  },
  web_image_dropped: function(drop) {
    var _this = this;
    var sizer = pictureGrabber.size_image(drop.file.url);
    sizer.then(function(res) {
      var url = res.url;
      drop.file.url = url;
      _this.controller.set('model.image_field', drop.file.url);
      _this.find_picture(drop.file.url);
    });
  },
  file_selected: function(file, type) {
    var _this = this;
    var reader = null;
    if(file && file.localURL) {
      // large data URLs seem to barf on iOS when drawing to a canvas or as an img src
      reader = RSVP.resolve({target: {result: file.localURL}});
    } else {
      reader = contentGrabbers.read_file(file);
    }
    if(type == 'avatar' && contentGrabbers.avatar_result) {
      contentGrabbers.avatar_result(true, 'loading');
    } else if(type == 'badge' && contentGrabbers.badge_result) {
      contentGrabbers.badge_result(true, 'loading');
    }
    var sizer = reader.then(function(data) {
      window.result = data.target.result;
      return pictureGrabber.size_image(data.target.result);
    });

    var force_data_url = sizer.then(function(res) {
      if(res.url && res.url.match(/^data/)) {
        return RSVP.resolve(res);
      } else {
        return contentGrabbers.read_file(file).then(function(data) {
          res.url = data.target.result;
          return RSVP.resolve(res);
        });
      }
    });

    force_data_url.then(function(res) {
      var url = res.url;
      if(type == 'avatar' || type == 'badge') {
        var content_type = (url.split(/:/)[1] || "").split(/;/)[0];
        var image = CoughDrop.store.createRecord('image', {
          url: url,
          content_type: content_type,
          width: res.width || pictureGrabber.default_size,
          height: res.height || pictureGrabber.default_size,
          avatar: (type == 'avatar'),
          badge: (type == 'badge'),
          license: {
            type: 'private'
          }
        });
        contentGrabbers.save_record(image).then(function(res) {
          if(type == 'avatar' && contentGrabbers.avatar_result) {
            contentGrabbers.avatar_result(true, res);
          } else if(type == 'badge' && contentGrabbers.badge_result) {
            contentGrabbers.badge_result(true, res);
          } else {
            console.error("nothing to handle successful image upload");
          }
        }, function(err) {
          if(type == 'avatar' && contentGrabbers.avatar_result) {
            contentGrabbers.avatar_result(false, err);
          } else if(type == 'badge' && contentGrabbers.badge_result) {
            contentGrabbers.badge_result(false, err);
          } else {
            console.error("nothing to handle failed avatar upload");
          }
        });
      } else {
        _this.controller.set('image_preview', {
          url: url,
          name: file.name,
          editor: null
        });
      }
    });
  },
  clear: function() {
    this.clear_image_preview();
    this.controller.set('image_search', null);
    var stream = this.controller.get('webcam.stream');
    if(stream && stream.stop) {
      stream.stop();
    } else if(stream && stream.getTracks) {
      stream.getTracks().forEach(function(track) {
        if(track.stop) {
          track.stop();
        }
      });
    }
    this.controller.set('webcam', null);
    $('#webcam_video').attr('src', '');
    $('#image_upload').val('');
  },
  clear_image_preview: function() {
    this.controller.set('image_preview', null);
  },
  default_image_preview_license: function() {
    var user = app_state.get('currentUser');
    if(user && this.controller.get('image_preview')) {
      if(!this.controller.get('image_preview.license')) {
       this.controller.set('image_preview.license', {type: 'private'});
      }
      if(!this.controller.get('image_preview.license.author_name') && this.controller.get('image_preview.license')) {
        this.controller.set('image_preview.license.author_name', user.get('user_name'));
      }
      if(!this.controller.get('image_preview.license.author_url') && this.controller.get('image_preview.license')) {
        this.controller.set('image_preview.license.author_url', user.get('profile_url'));
      }
    }
  },
  pick_preview: function(preview) {
    var license = {
      type: preview.license,
      copyright_notice_url: preview.license_url,
      source_url: preview.source_url,
      author_name: preview.author,
      author_url: preview.author_url,
      uneditable: true
    };

    this.controller.set('image_preview', {
      url: preview.image_url,
      search_term: this.controller.get('image_search.term'),
      external_id: preview.id,
      protected: preview.protected,
      protected_source: preview.protected_source,
      finding_user_name: preview.finding_user_name,
      content_type: preview.content_type,
      license: license
    });
  },
  find_picture: function(text, user_name) {
    if(text && (text.match(/^http/))) {
      var _this = this;
      _this.controller.set('image_search', null);
      persistence.ajax('/api/v1/search/proxy?url=' + encodeURIComponent(text), { type: 'GET'
      }).then(function(data) {
        _this.controller.set('image_preview', {
          url: data.data,
          content_type: data.content_type,
          source_url: text
        });
      }, function(xhr, message) {
        var error = i18n.t('not_available', "Image retrieval failed unexpectedly.");
        if(message && message.error == "not online") {
          error = i18n.t('not_online_image_proxy', "Cannot retrieve image, please connect to the Internet first.");
        }
        _this.controller.set('image_preview', {
          error: error
        });
      });
    } else if(text.match(/^data:/)) {
      this.controller.set('image_preview', {
        url: text
      });
      this.controller.set('image_search', null);
    } else {
      this.controller.set('image_preview', null);
      this.controller.set('image_search', {term: text});
      var _this = this;
      if(!persistence.get('online')) {
        _this.controller.set('image_search.error', i18n.t('not_online_image_search', "Cannot search, please connect to the Internet first."));
        return;
      }

      _this.picture_search(this.controller.get('image_library'), text, user_name).then(function(data) {
        _this.controller.set('image_search.previews', data);
        _this.controller.set('image_search.previews_loaded', true);
      }, function(err) {
        _this.controller.set('image_search.error', err);
      });
    }
  },
  picture_search: function(library, text, user_name, fallback) {
    var _this = this;
    var search = _this.open_symbols_search;
    if(library == 'flickr') {
      search = _this.flickr_search;
    } else if(library == 'public_domain') {
      search = _this.public_domain_image_search;
    } else if(library == 'pixabay_photos') {
      search = function(str) { return _this.pixabay_search(str, 'photo'); };
    } else if(library == 'pixabay_vectors') {
      search = function(str) { return _this.pixabay_search(str, 'vector'); };
    } else if(library == 'giphy_asl') {
      search = function(str) { return _this.protected_search(str, 'giphy_asl', user_name, fallback); };
    } else if(library == 'lessonpix') {
      search = function(str) { return _this.protected_search(str, library, user_name, fallback); };
    } else if(library == 'openclipart') {
      search = _this.openclipart_search;
    }
    return search(text);
  },
  protected_search: function(text, library, user_name, fallback) {
    user_name = user_name || (this.controller && this.controller.get('board.user_name')) || '';
    var _this = this;
    return persistence.ajax('/api/v1/search/protected_symbols?library=' + encodeURIComponent(library) + '&q=' + encodeURIComponent(text) + '&user_name=' + encodeURIComponent(user_name), { type: 'GET'
    }).then(function(data) {
      data.forEach(function(img) {
        img.image_url = CoughDrop.Image.personalize_url(img.image_url, app_state.get('currentUser.user_token'));
      });
      return data;
    }, function(xhr, message) {
      if(fallback) {
        return _this.open_symbols_search(text);
      } else {
        message = message || {error: 'invalid search'};
        return RSVP.reject(message.error);
      }
    });
  },
  open_symbols_search: function(text) {
    return persistence.ajax('/api/v1/search/symbols?q=' + encodeURIComponent(text), { type: 'GET'
    }).then(function(data) {
      return data;
    }, function(xhr, message) {
      var error = i18n.t('not_available', "Image retrieval failed unexpectedly.");
      if(message && message.error == "not online") {
        error = i18n.t('not_online_image_search', "Cannot search, please connect to the Internet first.");
      }
      return RSVP.reject(error);
    });
  },
  flickr_search: function(text) {
    if(!window.flickr_key) {
      return RSVP.reject(i18n.t('flickr_not_configured', "Flickr hasn't been properly configured for CoughDrop"));
    }
    // https://api.flickr.com/services/rest/?method=flickr.photos.search&api_key=5b397c920edee06dafeb630957e0a99e&text=cat&safe_search=2&media=photos&extras=license%2C+owner_name&format=json&nojsoncallback=1
    return persistence.ajax('https://api.flickr.com/services/rest/?method=flickr.photos.search&api_key=' + window.flickr_key + '&text=' + text + '&safe_search=1&media=photos&license=2%2C3%2C4%2C5%2C6%2C7&extras=license%2C+owner_name&format=json&nojsoncallback=1', { type: 'GET'
    }).then(function(data) {
      var res = [];

      var licenses = {
        '1': {name: 'CC By_NC-SA', url: 'http://creativecommons.org/licenses/by-nc-sa/2.0/'},
        '2': {name: 'CC By_NC', url: 'http://creativecommons.org/licenses/by-nc/2.0/'},
        '3': {name: 'CC By_NC-ND', url: 'http://creativecommons.org/licenses/by-nc-nd/2.0/'},
        '4': {name: 'CC By', url: 'http://creativecommons.org/licenses/by/2.0/'},
        '5': {name: 'CC By-SA', url: 'http://creativecommons.org/licenses/by-sa/2.0/'},
        '6': {name: 'CC By-ND', url: 'http://creativecommons.org/licenses/by-nd/2.0/'},
        '7': {name: 'public domain', url: 'https://www.flickr.com/commons/usage/'}
      };

      (((data || {}).photos || {}).photo || []).forEach(function(photo) {
        var license = licenses[photo.license];
        if(license) {
          res.push({
            image_url: "https://farm" + photo.farm + ".staticflickr.com/" + photo.server + "/" + photo.id + "_" + photo.secret + "_n.jpg",
            thumbnail_url: "https://farm" + photo.farm + ".staticflickr.com/" + photo.server + "/" + photo.id + "_" + photo.secret + "_n.jpg",
            content_type: 'image/jpeg',
            license: license.name,
            author: photo.ownername,
            author_url: "https://www.flickr.com/people/" + photo.owner + "/",
            license_url: license.url,
            source_url: "https://www.flickr.com/photos/" + photo.id + "/",
            extension: 'jpg'
          });
        }
      });
      return res.slice(0, 20);
    }, function(xhr, message) {
      return i18n.t('not_available', "Image retrieval failed unexpectedly.");
    });
  },
  openclipart_search: function(text) {
    return persistence.ajax('https://openclipart.org/search/json/?query=' + text + '&amount=30', {type: 'GET'
    }).then(function(data) {
      var res = [];
      ((data || {}).payload || []).forEach(function(hit) {
        res.push({
          image_url: hit.svg.url,
          thumbnail_url: hit.svg.url,
          content_type: 'image/svg',
          width: hit.dimensions.png_thumb.width,
          height: hit.dimensions.png_thumb.height,
          license: 'public domain',
          author: hit.uploader,
          author_url: 'https://creativecommons.org/publicdomain/zero/1.0/',
          license_url: 'https://creativecommons.org/publicdomain/zero/1.0/',
          source_url: hit.detail_link,
          extension: 'svg'
        });
      });
      console.log(res);
      return res;
    }, function(xhr, message) {
      return i18n.t('not_available', "Image retrieval failed unexpectedly.");
    });
  },
  pixabay_search: function(text, filter) {
    if(!window.pixabay_key) {
      return RSVP.reject(i18n.t('pixabay_not_configured', "Pixabay hasn't been properly configured for CoughDrop"));
    }
    var type = 'photo';
    if(filter == 'vector') { type = 'vector'; }
    return persistence.ajax('https://pixabay.com/api/?key=' + window.pixabay_key + '&q=' + text + '&image_type=' + type + '&per_page=30&safesearch=true', { type: 'GET'
    }).then(function(data) {
      var res = [];
      ((data || {}).hits || []).forEach(function(hit) {
        var content_type = 'image/jpeg';
        var ext = 'jpg';
        if(hit.webformatURL && hit.webformatURL.match(/png$/)) {
          content_type = 'image/png';
          ext = 'png';
        }
        res.push({
          image_url: hit.webformatURL,
          thumbnail_url: hit.previewURL || hit.webformatURL,
          content_type: content_type,
          width: hit.webformatWidth,
          height: hit.webformatHeight,
          license: 'public domain',
          author: 'unknown',
          author_url: 'https://creativecommons.org/publicdomain/zero/1.0/',
          license_url: 'https://creativecommons.org/publicdomain/zero/1.0/',
          source_url: hit.pageURL,
          extension: ext
        });
      });
      console.log(res);
      return res;
    }, function(xhr, message) {
      return i18n.t('not_available', "Image retrieval failed unexpectedly.");
    });
  },
  public_domain_image_search: function(text) {
    // https://en.wikipedia.org/w/api.php?action=query&titles=Albert%20Einstein&prop=images&format=json
    // https://en.wikipedia.org/w/api.php?action=query&prop=imageinfo&iiprop=extmetadata&titles=File:Albert%20Einstein%20(Nobel).png|File:Albert%20Einstein%27s%20exam%20of%20maturity%20grades%20(color2).jpg&format=json
    // https://www.googleapis.com/customsearch/v1?q=cat&cx=014949904870326116447%3Awlqrabmc6cu&rights=cc_publicdomain&safe=medium&searchType=image&key={YOUR_API_KEY}
    return persistence.ajax('https://www.googleapis.com/customsearch/v1?q=' + text + '&cx=014949904870326116447%3Awlqrabmc6cu&rights=cc_publicdomain&safe=medium&key=' + window.custom_search_key, { type: 'GET'
    }).then(function(data) {
      var res = [];
      console.log(data);
      (data.items || []).forEach(function(item) {
        console.log(item);
        var img = item.image || {};
        var cse = ((item.pagemap || {}).cse_image || [])[0] || {};
        var mime = item.mime;
        if(cse.src && cse.src.match(/\.jpe?g/)) {
          mime = 'image/jpeg';
        } else if(cse.src && cse.src.match(/\.png/)) {
          mime = 'image/png';
        }
        if(mime && cse.src) {
          res.push({
            image_url: "https://images.weserv.nl/?url=" + (cse.src || item.link).replace(/^https?:\/\//, ''),
            thumbnail_url: "https://images.weserv.nl/?url=" + (cse.src || item.link).replace(/^https?:\/\//, ''),
            license: 'public domain',
            content_type: mime,
            width: img.width,
            height: img.height,
            author: item.displayLink,
            author_url: item.formattedUrl || img.contextLink,
            license_url: 'https://creativecommons.org/publicdomain/zero/1.0/',
            source_url: item.formattedUrl || img.contextLink
          });
        }
      });
      return res;
    }, function(xhr, message) {
        return i18n.t('not_available', "Image retrieval failed unexpectedly.");
    });
  },
  edit_image_preview: function() {
    var preview = this.controller.get('image_preview');
    var _this = this;

    (new RSVP.Promise(function(resolve, reject) {
      if(preview.url.match(/^http/)) {
        persistence.ajax('/api/v1/search/proxy?url=' + encodeURIComponent(preview.url), { type: 'GET'
        }).then(function(data) {
          resolve(data.data);
        }, function(xhr, message) {
          reject({error: "couldn't retrieve image data"});
        });
      } else {
        resolve(preview.url);
      }
    })).then(function(url) {
      editManager.stash_image({url: url});
      _this.controller.set('image_preview.editor', true);
    });
  },
  clear_image: function() {
    this.clear();
    this.controller.set('model.image', null);
  },
  edit_image: function() {
    var image = this.controller.get('model.image');

    var _this = this;
    var sizer = pictureGrabber.size_image(image.get('url'));
    sizer.then(function(res) {
      var url = res.url;
      _this.controller.set('image_preview', {
        url: url,
        content_type: image.get('content_type'),
        name: "",
        license: image.get('license'),
        editor: null
      });
      _this.edit_image_preview();
    });
  },
  word_art: function(word) {
    var _this = this;
    editManager.stash_image({word: word});
    _this.controller.set('image_preview', {
      editor: true,
      word_editor: true,
      license: {
        type: 'CC By',
        copyright_notice_url: 'https://creativecommons.org/licenses/by/3.0/us/',
        author_name: 'CoughDrop',
        author_url: 'https://www.mycoughdrop.com',
        uneditable: true
      }
    });
  },
  save_image: function(data_url) {
    var content_type = null;
    if(data_url.match(/^data:/)) {
      content_type = data_url.split(/;/)[0].split(/:/)[1];
    }

    var image_load = new RSVP.Promise(function(resolve, reject) {
      var i = new window.Image();
      i.onload = function() {
        resolve({
          width: i.width,
          height: i.height
        });
      };
      i.onerror = function() {
        reject({error: "image calculation failed"});
      };
      i.src = data_url;
    });

    var save_image = image_load.then(function(data) {
      var image = CoughDrop.store.createRecord('image', {
        url: data_url,
        content_type: content_type,
        width: data.width,
        height: data.height,
        license: {
          type: 'private'
        }
      });
      var _this = this;
      return contentGrabbers.save_record(image);
    });
    return save_image;
  },
  save_image_preview: function(preview, force_content_type) {
    var _this = this;
    if(preview.url.match(/^data:/)) {
      emberSet(preview, 'content_type', force_content_type || preview.content_type || preview.url.split(/;/)[0].split(/:/)[1]);
    }
    if(!preview.license || !preview.license.copyright_notice_url) {
      emberSet(preview, 'license', preview.license || {});
      var license_url = null;
      var licenses = CoughDrop.licenseOptions;
      for(var idx = 0; idx < licenses.length; idx++) {
        if(licenses[idx].id == preview.license.type) {
          license_url = licenses[idx].url;
        }
      }
      emberSet(preview, 'license.copyright_notice_url', license_url);
    }
    var image_load = new RSVP.Promise(function(resolve, reject) {
      var i = new window.Image();
      i.onload = function() {
        resolve({
          width: i.width,
          height: i.height
        });
      };
      i.onerror = function() {
        reject({error: "image calculation failed"});
      };
      i.src = preview.url;
    });

    var save_image = image_load.then(function(data) {
      var image = CoughDrop.store.createRecord('image', {
        url: persistence.normalize_url(preview.url),
        content_type: preview.content_type,
        width: data.width,
        height: data.height,
        external_id: preview.external_id,
        search_term: preview.search_term,
        license: preview.license,
        protected: preview.protected,
        protected_source: preview.protected_source,
        finding_user_name: preview.finding_user_name
      });
      var _this = this;
      return contentGrabbers.save_record(image);
    });
    return save_image;
  },
  select_image_preview: function(url, force_content_type) {
    var preview = this.controller && this.controller.get('image_preview');
    if(!preview || (!preview.url && !preview.word_editor)) { return; }
    this.controller.set('model.pending_image', true);
    var _this = this;

    if(this.controller.get('image_preview.editor')) {
      if(!url) {
        if(_this.edited_image_data) {
          _this.select_image_preview(_this.edited_image_data);
        } else {
          editManager.get_edited_image().then(function(data) {
            _this.select_image_preview(data, 'image/png');
          }, function() {
          });
        }
        return;
      } else {
        emberSet(preview, 'url', url);
      }
    }
    var save_image = this.save_image_preview(preview, force_content_type);
    var button_id = _this.controller.get('model.id');
    save_image.then(function(image) {
      // TODO: if the image doesn't have a label yet, go ahead and set
      // it to the filename of this image pretty formatted (I guess also
      // strip off any trailing numbers).
      _this.controller.set('model.image', image);
      _this.clear();
      var button_image = {url: image.get('url'), id: image.id};
      editManager.change_button(button_id, {
        'image': image,
        'image_id': image.id
      });
      _this.controller.set('model.pending_image', false);
    }).then(null, function(err) {
      err = err || {};
      err.error = err.error || "unexpected error";
      coughDropExtras.track_error("upload failed: " + err.error);
      alert(i18n.t('upload_failed', "upload failed:" + err.error));
      _this.controller.set('model.pending_image', false);
    });
  },
  save_pending: function() {
    var _this = this;
    if(this.controller.get('image_preview')) {
      this.select_image_preview();
    } else if(this.controller.get('model.image')) {
      var license = this.controller.get('model.image.license');
      var original = this.controller.get('original_image_license') || {};
      emberSet(license, 'type', license.type || original.type);
      if(license.type != original.type || license.author_name != original.author_name || license.author_url != original.author_url) {
        this.controller.set('model.pending_image', false);
        this.controller.get('model.image').save().then(function() {
          _this.controller.set('model.pending_image', false);
        }, function() {
          alert(i18n.t('save_failed', "Saving settings failed!"));
          _this.controller.set('model.pending_image', false);
        });
      }
    }
  },
  webcam_available: function() {
    return !!(navigator.getUserMedia || contentGrabbers.capture_types().image);
  },
  user_media_ready: function(stream, stream_id) {
    var video = document.querySelector('#webcam_video');
    var _this = this;
    if(video) {
      video.src = window.URL.createObjectURL(stream);
    }
    if(stream_id) {
      stashes.persist('last_stream_id', stream_id);
    }
    _this.clear_image_preview();
    _this.controller.set('image_search', null);
    var streams = _this.controller.get('webcam.video_streams');
    _this.controller.set('webcam', {
      stream: stream,
      showing: true,
      stream_id: stream_id,
      video_streams: streams
    });
    var enumerator = window.enumerateMediaDevices || (window.navigator && window.navigator.mediaDevices && window.navigator.mediaDevices.enumerateDevices);
    if(!enumerator && window.MediaStreamTrack && window.MediaStreamTrack.getSources) {
      enumerator = function() {
        return new RSVP.Promise(function(resolve, reject) {
          window.MediaStreamTrack.getSources(function(sources) {
            resolve(sources);
          });
        });
      };
    }
    if(enumerator && !streams) {
      enumerator().then(function(list) {
        var video_streams = [];
        list.forEach(function(device) {
          if(device.kind == 'videoinput' || device.kind == 'video') {
            video_streams.push({
              id: device.deviceId || device.id,
              label: device.label || ('camera ' + (video_streams.length + 1))
            });
          }
        });
        // If there's nothing to swap out, don't bother telling anyone
        if(video_streams.length <= 1) {
          video_streams = [];
        }
        if(_this.controller.get('webcam')) {
          _this.controller.set('webcam.video_streams', video_streams);
        }
      }, function() { });
    }
  },
  start_webcam: function() {
    var _this = this;
    // TODO: cross-browser
    if(navigator.device && contentGrabbers.capture_types().image) {
      navigator.device.capture.captureImage(function(files) {
        var media_file = files[0];
        var file = new window.File(media_file.name, media_file.localURL, media_file.type, media_file.lastModifiedDate, media_file.size);
        _this.file_selected(file);
      }, function() { }, {limit: 1});
    } else if(navigator.getUserMedia) {
      var last_stream_id = stashes.get('last_stream_id');
      var constraints = {video: true};
      if(last_stream_id) {
        constraints.video = {
          optional: [{
            sourceId: last_stream_id,
            deviceId: last_stream_id
          }]
        };
      }
      navigator.getUserMedia(constraints, function(stream) {
        _this.user_media_ready(stream, last_stream_id);
      }, function() {
        console.log("permission not granted");
      });
    }
  },
  swap_streams: function() {
    var video = document.querySelector('#webcam_video');
    var current_stream_id = this.controller.get('webcam.stream_id');
    var streams = this.controller.get('webcam.video_streams');
    var index = 0;
    if(streams) {
      for(var idx = 0; idx < streams.length; idx++) {
        if(current_stream_id && streams[idx].id == current_stream_id) {
          index = idx;
        }
      }
    }
    var _this = this;
    if(streams && streams.length > 1) {
      index++;
      if(index > streams.length - 1) {
        index = 0;
      }
      var stream_id = streams[index] && streams[index].id;
      if(stream_id) {
        var stream = _this.controller.get('webcam.stream');
        if(stream && stream.stop) {
          stream.stop();
        } else if(stream && stream.getTracks) {
          stream.getTracks().forEach(function(track) {
            if(track.stop) {
              track.stop();
            }
          });
        }
        if(video) { video.src = null; }
        navigator.getUserMedia({
          video: {
            optional: [{
              sourceId: stream_id,
              deviceId: stream_id
            }]
          }
        }, function(stream) {
          _this.user_media_ready(stream, stream_id);
        }, function() {
          console.log("permission not granted");
        });
      }
    }
  },
  toggle_webcam: function() {
    // TODO: needs a real home and non-suck
    // TODO: cross-browser - https://developer.mozilla.org/en-US/docs/WebRTC/taking_webcam_photos
    var video = document.querySelector('#webcam_video');
    var canvas = document.querySelector('#webcam_canvas');
    var ctx = canvas && canvas.getContext('2d');
    if(!ctx || this.controller.get('webcam.snapshot')) {
      this.controller.set('image_preview', null);
      this.controller.set('webcam.snapshot', false);
    } else if(this.controller.get('webcam.stream')) {
      ctx.drawImage(video, 0, 100, 800, 600);
      var data = canvas.toDataURL('image/png');
      this.controller.set('image_preview', {
        url: data
      });
      this.controller.set('webcam.snapshot', true);
      this.controller.set('image_preview.editor', null);
    }
  },
  load_badge: function(badge) {
    editManager.stashedBadge = badge;
  },
  retrieve_badge: function() {
    return editManager.retrieve_badge();
  },
  done_with_badge: function() {
    editManager.stashedBadge = null;
  }
}).create();

var videoGrabber = EmberObject.extend({
  setup: function(controller) {
    var _this = this;
    this.controller = controller;
    _this.controller.addObserver('video_preview', _this, _this.default_video_preview_license);
  },
  clear: function() {
    var stream = this.controller && this.controller.get('video_recording.stream');
    if(stream && stream.stop) {
      stream.stop();
    } else if(stream && stream.getTracks) {
      stream.getTracks().forEach(function(track) {
        if(track && track.stop) {
          track.stop();
        }
      });
    }
    this.toggle_recording_video('stop');
  },
  clear_video_work: function() {
    $('#video_upload').val('');
    if(this.controller) {
      this.controller.set('video_preview', null);
    }
    this.clear();
    if(this.controller) {
      this.controller.set('video_recording', null);
    }
  },
  default_video_preview_license: function() {
    var user = app_state.get('currentUser');
    if(user && this.controller && this.controller.get('video_preview')) {
      if(!this.controller.get('video_preview.license')) {
       this.controller.set('video_preview.license', {type: 'private'});
      }
      if(!this.controller.get('video_preview.license.author_name') && this.controller.get('video_preview.license')) {
        this.controller.set('video_preview.license.author_name', user.get('user_name'));
      }
      if(!this.controller.get('sound_preview.license.author_url') && this.controller.get('video_preview.license')) {
        this.controller.set('video_preview.license.author_url', user.get('profile_url'));
      }
    }
  },
  file_selected: function(file) {
    var _this = this;
    var reader = contentGrabbers.read_file(file);
    reader.then(function(data) {
      contentGrabbers.read_file(file, 'blob').then(null, function() { return RSVP.resolve(null); }).then(function(blob) {
        var res = {
          local_url: file.localURL,
          url: data.target.result,
          blob: blob,
          name: file.name
        };
        if(window.resolveLocalFileSystemURL && file.localURL) {
          window.resolveLocalFileSystemURL(file.localURL, function(e) {
            if(e && e.toURL) {
              res.local_url = e.toURL();
            }
            _this.controller.set('video_preview', res);
          });
        } else {
          _this.controller.set('video_preview', res);
        }
      });
    });
  },
  recorder_available: function() {
    return !!(capabilities.subsystem != 'Kindle' && (navigator.getUserMedia || contentGrabbers.capture_types().video));
  },
  record_video: function() {
    var _this = this;
    this.controller.set('video_recording', {
      stream: this.controller.get('video_recording.stream'),
      ready: true
    });
    this.controller.set('video_preview', null);

    if(contentGrabbers.capture_types().video) {
      navigator.device.capture.captureVideo(function(files) {
        var media_file = files[0];
        var file = new window.File(media_file.name, media_file.localURL, media_file.type, media_file.lastModifiedDate, media_file.size);
        _this.file_selected(file);
      }, function() { }, {limit: 1});
    } else if(navigator.getUserMedia) {
      if(this.controller.get('video_recording.stream')) {
        _this.user_media_ready(this.controller.get('video_recording.stream'));
        return;
      }

      var last_stream_id = stashes.get('last_stream_id');
      var constraints = {video: true, audio: true};
      if(last_stream_id) {
        constraints.video = {
          optional: [{
            sourceId: last_stream_id,
            deviceId: last_stream_id
          }]
        };
      }
      navigator.getUserMedia(constraints, function(stream) {
        _this.user_media_ready(stream, last_stream_id);
      }, function() {
        console.log("permission not granted");
      });
    }
  },
  swap_streams: function() {
    var current_stream_id = this.controller.get('video_recording.stream_id');
    var streams = this.controller.get('video_recording.video_streams');
    var index = 0;
    if(streams) {
      for(var idx = 0; idx < streams.length; idx++) {
        if(current_stream_id && streams[idx].id == current_stream_id) {
          index = idx;
        }
      }
    }
    var _this = this;
    if(streams && streams.length > 1) {
      index++;
      if(index > streams.length - 1) {
        index = 0;
      }
      var stream_id = streams[index] && streams[index].id;
      if(stream_id) {
        var stream = _this.controller.get('video_recording.stream');
        if(stream && stream.stop) {
          stream.stop();
        } else if(stream && stream.getTracks) {
          stream.getTracks().forEach(function(track) {
            if(track.stop) {
              track.stop();
            }
          });
        }
        if(this.controller.get('video_recording')) {
          this.controller.set('video_recording.video_url', null);
        }
        navigator.getUserMedia({
          video: {
            optional: [{
              sourceId: stream_id,
              deviceId: stream_id
            }]
          }
        }, function(stream) {
          _this.user_media_ready(stream, stream_id);
        }, function() {
          console.log("permission not granted");
        });
      }
    }
  },
  setup_media_recorder: function(stream, options) {
    var mediaRecorder = null;
    var _this = this;
    try {
      mediaRecorder = new window.MediaRecorder(stream, options);
    } catch (e0) {
      console.log('Unable to create MediaRecorder with options Object: ', e0);
      try {
        options = {mimeType: 'video/webm,codecs=vp9', bitsPerSecond: 100000};
        mediaRecorder = new window.MediaRecorder(stream, options);
      } catch (e1) {
        console.log('Unable to create MediaRecorder with options Object: ', e1);
        try {
          options = 'video/vp8'; // Chrome 47
          mediaRecorder = new window.MediaRecorder(stream, options);
        } catch (e2) {
          _this.controller.set('video_recording.error', true);
          console.error('Exception while creating MediaRecorder:', e2);
          return null;
        }
      }
    }
    return mediaRecorder;
  },
  user_media_ready: function(stream, stream_id) {
    var options = {mimeType: 'video/webm', bitsPerSecond: 100000};
    var _this = this;
    videoGrabber.recorded_blobs = [];
    var mediaRecorder = _this.setup_media_recorder(stream, options);
    if(!mediaRecorder) { return; }
    _this.controller.set('video_recording.error', false);

    mediaRecorder.addEventListener('dataavailable', function(event) {
      videoGrabber.recorded_blobs.push(event.data);
    });
    mediaRecorder.stopped = function() {
      var started = _this.controller.get('video_recording.started');
      var now = (new Date()).getTime();
      var blob = new Blob(videoGrabber.recorded_blobs, {type: 'video/webm'});
      videoGrabber.recorded_blobs = [];
      var reader = contentGrabbers.read_file(blob);
      reader.then(function(data) {
        _this.controller.set('video_preview', {
          from_recording: true,
          url: data.target.result,
          duration: (now - started) / 1000,
          name: i18n.t('recorded_video', "Recorded video")
        });
        if(_this.controller.get('video_recording')) {
          _this.controller.set('video_recording.ready', false);
        }
      });
    };
    mediaRecorder.addEventListener('stop', function() {
      mediaRecorder.stopped();
    });
    mediaRecorder.addEventListener('recordingdone', function() {
      mediaRecorder.stopped();
    });

    if(mediaRecorder.stream != stream) {
      _this.clear_video_work();
    }
    var video_url = window.URL.createObjectURL(stream);
    if(stream_id) {
      stashes.persist('last_stream_id', stream_id);
    }
    var streams = _this.controller.get('video_recording.video_streams');
    _this.controller.set('video_recording', {
      media_recorder: mediaRecorder,
      video_url: video_url,
      stream: stream,
      stream_id: stream_id,
      video_streams: streams
    });
    var enumerator = window.enumerateMediaDevices || (window.navigator && window.navigator.mediaDevices && window.navigator.mediaDevices.enumerateDevices);
    if(!enumerator && window.MediaStreamTrack && window.MediaStreamTrack.getSources) {
      enumerator = function() {
        return new RSVP.Promise(function(resolve, reject) {
          window.MediaStreamTrack.getSources(function(sources) {
            resolve(sources);
          });
        });
      };
    }
    if(enumerator && !streams) {
      enumerator.call(window.navigator.mediaDevices || window).then(function(list) {
        var video_streams = [];
        list.forEach(function(device) {
          if(device.kind == 'videoinput' || device.kind == 'video') {
            video_streams.push({
              id: device.deviceId || device.id,
              label: device.label || ('camera ' + (video_streams.length + 1))
            });
          }
        });
        // If there's nothing to swap out, don't bother telling anyone
        if(video_streams.length <= 1) {
          video_streams = [];
        }
        if(_this.controller.get('video_recording')) {
          _this.controller.set('video_recording.video_streams', video_streams);
        }
      });
    }
  },
  toggle_recording_video: function(action) {
    if(!action) {
      action = this.controller && this.controller.get('video_recording.recording') ? 'stop' : 'start';
    }
    var mr = this.controller && this.controller.get('video_recording.media_recorder');
    if(action == 'start' && mr && mr.state == 'inactive') {
      this.controller.set('video_recording.video_url', window.URL.createObjectURL(this.controller.get('video_recording.stream')));
      this.controller.set('video_recording.blob', null);
      this.controller.set('video_recording.recording', true);
      this.controller.set('video_recording.started', (new Date()).getTime());
      mr.start(100);
    } else if(action == 'stop' && mr && mr.state == 'recording') {
      this.controller.set('video_recording.recording', false);
      this.controller.set('video_recording.video_url', null);
      mr.stop();
    }
  },
  measure_duration: function(url, fallback_duration) {
    return new RSVP.Promise(function(resolve, reject) {
      var a = document.createElement('video');
      var done = false;
      a.preload = 'metadata';
      a.ondurationchange = function() {
        var duration = fallback_duration;
        if(a.duration && isFinite(a.duration)) {
          duration = a.duration;
        }
        done = true;
        resolve({
          duration: duration
        });
      };
      a.onerror = function() {
        done = true;
        reject({error: "video calculation failed"});
      };
      runLater(function() {
        if(!done) {
          var e = $("#video_elem")[0];
          var duration = (e && e.duration) || 10;
          resolve({
            duration: duration
          });
        }
      }, 500);
      a.src = url;
    });
  },
  select_video_preview: function() {
    var preview = this.controller && this.controller.get('video_preview');
    if(!preview || !preview.url) { return; }
    this.controller.set('video_preview.saving', true);
    var _this = this;

    _this.controller.sendAction('video_pending');

    if(preview.url.match(/^data:/)) {
      preview.content_type = preview.content_type || preview.url.split(/;/)[0].split(/:/)[1];
    }
    if(!preview.license || !preview.license.copyright_notice_url) {
      var preview_license = preview.license || {};
      var license_url = null;
      var licenses = CoughDrop.licenseOptions;
      for(var idx = 0; idx < licenses.length; idx++) {
        if(licenses[idx].id == preview_license.type) {
          license_url = licenses[idx].url;
        }
      }
      preview_license.copyright_notice_url = license_url;
      emberSet(preview, 'license', preview_license);
    }

    var video_load = _this.measure_duration(preview.local_url || preview.url, preview.duration);

    var save_video = video_load.then(function(data) {
      var video = CoughDrop.store.createRecord('video', {
        content_type: preview.content_type || '',
        url: preview.url,
        blob: preview.blob,
        duration: data.duration,
        license: preview.license
      });

      return contentGrabbers.save_record(video);
    });

    save_video.then(function(video) {
      _this.controller.set('video', video);
      _this.clear_video_work();
      _this.controller.sendAction('video_ready', video.get('id'));
    }, function(err) {
      err = err || {};
      err.error = err.error || "unexpected error";
      coughDropExtras.track_error("upload failed: " + err.error);
      alert(i18n.t('upload_failed', "upload failed: " + err.error));
      _this.controller.set('video_preview.saving', false);
      _this.controller.sendAction('video_not_ready');
    });
  },
  save_pending: function() {
    var _this = this;
    if(this.controller.get('video_preview')) {
      this.select_video_preview();
    } else if(this.controller.get('video')) {
      var license = this.controller.get('video.license');
      var original = this.controller.get('original_video_license') || {};
      if(license.type != original.type || license.author_name != original.author_name || license.author_url != original.author_url) {
        this.controller.set('pending_video', true);
        this.controller.get('video').save().then(function() {
          _this.controller.set('pending_video', false);
        }, function() {
          alert(i18n.t('save_failed', "Saving settings failed!"));
          _this.controller.set('pending_video', false);
        });
      }
    }
  },
}).create();

var soundGrabber = EmberObject.extend({
  setup: function(button, controller) {
    this.controller = controller;
    var _this = this;
    this.button = button;
    if(button) {
      runLater(function() {
        button.findContentLocally().then(function() {
          var sound = button.get('sound');
          if(sound) {
            sound.check_for_editable_license();
          }
        });
      });
    }
    _this.controller.set('browse_audio', null);
    _this.controller.addObserver('sound_preview', _this, _this.default_sound_preview_license);
  },
  clear: function() {
    var stream = this.controller.get('sound_recording.stream');
    if(stream && stream.stop) {
      stream.stop();
    } else if(stream && stream.getTracks) {
      stream.getTracks().forEach(function(track) {
        if(track && track.stop) {
          track.stop();
        }
      });
    }
    this.toggle_recording_sound('stop');
  },
  clear_sound_work: function() {
    this.controller.set('sound_preview', null);
    this.clear();
    this.controller.set('sound_recording', null);
    this.controller.set('browse_audio', null);
    $('#sound_upload').val('');
  },
  default_sound_preview_license: function() {
    var user = app_state.get('currentUser');
    if(user && this.controller.get('sound_preview')) {
      if(!this.controller.get('sound_preview.license')) {
       this.controller.set('sound_preview.license', {type: 'private'});
      }
      if(!this.controller.get('sound_preview.license.author_name') && this.controller.get('sound_preview.license')) {
        this.controller.set('sound_preview.license.author_name', user.get('user_name'));
      }
      if(!this.controller.get('sound_preview.license.author_url') && this.controller.get('sound_preview.license')) {
        this.controller.set('sound_preview.license.author_url', user.get('profile_url'));
      }
    }
  },
  file_selected: function(file) {
    var _this = this;
    var reader = contentGrabbers.read_file(file);
    this.controller.set('browse_audio', null);
    reader.then(function(data) {
      _this.controller.set('sound_preview', {
        url: data.target.result,
        name: file.name
      });
    });
  },
  recording_selected: function(file) {
    var error = modal.error;
    var _this = this;

    var type = null;
    if(file && file.type.match(/^audio/)) {
      type = 'sound';
    } else if(file && file.name.match(/\.zip$/)) {
      type = 'zip';
    }

    if(type == 'sound') {
      // upload the sound and then reload the list if on the recordings page
      var reader = contentGrabbers.read_file(file);
      var _this = this;
      if(_this.recordings_controller) {
        _this.recordings_controller.set('upload_status', {uploading: true});
      }
      reader.then(function(data) {
        _this.select_sound_preview({
          url: data.target.result,
          name: file.name
        }).then(function(sound) {
          if(_this.recordings_controller) {
            _this.recordings_controller.set('upload_status', null);
            _this.recordings_controller.load_recordings();
          }
        }, function(err) {
          if(_this.recordings_controller) {
            _this.recordings_controller.set('upload_status', {error: true});
          }
          error(i18n.t('sound_upload_failed', "Upload failed"));
        });
      });
    } else if(type == 'zip') {
      var progressor = EmberObject.create();
      modal.open('importing-recordings', progressor);
      // do the hard stuff
      var progress = contentGrabbers.upload_for_processing(file, '/api/v1/sounds/imports', {}, progressor);

      progress.then(function(sounds) {
        if(_this.recordings_controller) {
          _this.recordings_controller.load_recordings();
        }
        modal.close('importing-recordings');
        modal.success(i18n.t('sounds_imported', "Your recordings have been imported or updated!"));
      }, function() { });
    } else {
      modal.error(i18n.t('unrecognized_sound_type', "The file you uploaded doesn't appear to be a valid audio or zip file"));
      return;
    }
  },
  recorder_available: function() {
    return !!(capabilities.subsystem != 'Kindle' && (navigator.getUserMedia || contentGrabbers.capture_types().audio));
  },
  record_sound: function(auto_loading) {
    var _this = this;
    this.controller.set('sound_recording', {
      stream: this.controller.get('sound_recording.stream'),
      ready: true
    });
    this.controller.set('sound_preview', null);
    this.controller.set('browse_audio', null);

    function stream_ready(stream) {
      _this.controller.set('sound_recording.stream', stream);
      // TODO: not all browsers support webm..
      var mr = new window.MediaRecorder(stream, {mimeType: 'audio/webm'});
      _this.controller.set('sound_recording.media_recorder', mr);
      mr.addEventListener('dataavailable', function(event) {
        if(!_this.controller.get('sound_recording.blob') && _this.controller.get('sound_recording')) {
          _this.controller.set('sound_recording.blob', event.data);
        }
        _this.toggle_recording_sound('stop');
      });
      mr.stopped = function() {
        var temp_blob = _this.controller.get('sound_recording.blob');
        var blob = new Blob([temp_blob], {type: 'audio/webm'});
        var reader = contentGrabbers.read_file(blob);
        reader.then(function(data) {
          _this.controller.set('sound_preview', {
            from_recording: true,
            url: data.target.result,
            name: i18n.t('recorded_sound', "Recorded sound")
          });
          if(_this.controller.get('sound_recording')) {
            _this.controller.set('sound_recording.ready', false);
          }
        });
      };

      mr.addEventListener('recordingdone', function() {
        mr.stopped();
      });
      mr.addEventListener('stop', function() {
        mr.stopped();
      });

      return mr;
    }

    if(navigator.getUserMedia) {
      if(this.controller.get('sound_recording.stream')) {
        stream_ready(this.controller.get('sound_recording.stream'));
        return;
      }
      navigator.getUserMedia({audio: true}, function(stream) {
        var mr = stream_ready(stream);

        if(stream && stream.id && document.getElementById('sound_levels')) {
          var context = new window.AudioContext();
          var source = context.createMediaStreamSource(stream);
          var analyser = context.createAnalyser();
          var ctx = $('#sound_levels')[0].getContext('2d');
          analyser.smoothingTimeConstant = 0.3;
          analyser.fftSize = 1024;
          var js = context.createScriptProcessor(2048, 1, 1);
          js.onaudioprocess = function() {
            // get the average, bincount is fftsize / 2
            var array =  new Uint8Array(analyser.frequencyBinCount);
            analyser.getByteFrequencyData(array);
            var values = 0;
            var average;

            var length = array.length;

            // get all the frequency amplitudes
            for (var i = 0; i < length; i++) {
                values += array[i];
            }

            var average = values / length;
            var pct = average / 130;

            var gradient = ctx.createLinearGradient(0,50,0,250);
            gradient.addColorStop(1,'#00ff00');
            gradient.addColorStop(0.25,'#ffff00');
            gradient.addColorStop(0,'#ff0000');
            // clear the current state
            ctx.clearRect(0, 0, 400, 300);

            // set the fill style
            ctx.fillStyle=gradient;

            // create the meters
            ctx.fillRect(100,275,200,-250*pct);
          };
  //        source.connect(analyser);
  //        analyser.connect(js);
  //        js.connect(context.destination);
        }
      }, function() {
        console.log("permission not granted");
      });
    } else if(!auto_loading && contentGrabbers.capture_types().audio) {
      this.native_record_sound();
    }
  },
  native_record_sound: function() {
    var _this = this;
    if(contentGrabbers.capture_types().audio) {
      navigator.device.capture.captureAudio(function(files) {
        var media_file = files[0];
        var file = new window.File(media_file.name, media_file.localURL, media_file.type, media_file.lastModifiedDate, media_file.size);
        _this.file_selected(file);
      }, function() { }, {limit: 1});
    }
  },
  toggle_recording_sound: function(action) {
    var mr = this.controller.get('sound_recording.media_recorder');
    if(action != 'stop' && !mr && contentGrabbers.capture_types().audio) {
      this.native_record_sound();
      return;
    }
    if(!action) {
      action = this.controller.get('sound_recording.recording') ? 'stop' : 'start';
    }
    if(action == 'start' && mr && mr.state == 'inactive') {
      var _this = this;
      var delay = Ember.testing ? 0 : 500;
      var start = function() {
        _this.controller.set('sound_recording.blob', null);
        _this.controller.set('sound_recording.recording', true);
        mr.start(60000);
      };
      if(Ember.testing) {
        start();
      } else {
        runLater(start, 500);
      }
    } else if(action == 'stop' && mr && mr.state == 'recording') {
      this.controller.set('sound_recording.recording', false);
      mr.stop();
    }
  },
  select_sound_preview: function(preview) {
    preview = preview || (this.controller && this.controller.get('sound_preview'));
    if(!preview || !preview.url) { return; }
    var _this = this;

    if(this.controller) {
      this.controller.set('model.pending_sound', true);
    }
    if(preview.url.match(/^data:/)) {
      preview.content_type = preview.content_type || preview.url.split(/;/)[0].split(/:/)[1];
    }
    if(!preview.license || !preview.license.copyright_notice_url) {
      var preview_license = preview.license || {};
      var license_url = null;
      var licenses = CoughDrop.licenseOptions;
      for(var idx = 0; idx < licenses.length; idx++) {
        if(licenses[idx].id == preview_license.type) {
          license_url = licenses[idx].url;
        }
      }
      preview_license.copyright_notice_url = license_url;
      emberSet(preview, 'license', preview_license);
    }

    var sound_load = new RSVP.Promise(function(resolve, reject) {
      var a = new window.Audio();
      a.ondurationchange = function() {
        resolve({
          duration: a.duration
        });
      };
      a.onerror = function() {
        if(capabilities.installed_app) {
          resolve({duration: 1});
        } else {
          reject({error: "sound calculation failed"});
        }
      };
      a.src = preview.url;
    });

    var user_id = this.controller && this.controller.get('user_id');
    var save_sound = sound_load.then(function(data) {
      var sound = CoughDrop.store.createRecord('sound', {
        content_type: preview.content_type || '',
        url: preview.url,
        name: preview.name,
        duration: data.duration,
        transcription: preview.transcription,
        license: preview.license,
        user_id: user_id
      });

      return contentGrabbers.save_record(sound);
    });

    return save_sound.then(function(sound) {
      var button_sound = {url: sound.get('url'), id: sound.id};
      if(_this.controller) {
        _this.controller.set('model.sound', sound);
        sound.check_transcription();
        _this.clear_sound_work();
        if(_this.button) {
          editManager.change_button(_this.controller.get('model.id'), {
            'sound': sound,
            'sound_id': sound.id
          });
        }
        _this.controller.set('model.pending_sound', false);
      }
      return {
        url: sound.get('url'),
        id: sound.id
      };
    }, function(err) {
      err = err || {};
      err.error = err.error || "unexpected error";
      coughDropExtras.track_error("upload failed: " + err.error);
      alert(i18n.t('upload_failed', "upload failed: " + err.error));
      if(_this.controller) {
        _this.controller.set('model.pending_sound', false);
      }
    });
  },
  save_pending: function() {
    var _this = this;
    if(this.controller.get('sound_preview')) {
      this.select_sound_preview();
    } else if(this.controller.get('model.sound')) {
      var license = this.controller.get('model.sound.license');
      var original = this.controller.get('original_sound_license') || {};
      if(license.type != original.type || license.author_name != original.author_name || license.author_url != original.author_url) {
        this.controller.set('model.pending_sound', true);
        this.controller.get('model.sound').save().then(function() {
          _this.controller.set('model.pending_sound', false);
        }, function() {
          alert(i18n.t('save_failed', "Saving settings failed!"));
          _this.controller.set('model.pending_sound', false);
        });
      }
    }
  },
  browse_audio: function() {
    var controller = this.controller;
    controller.set('browse_audio', true);
  },
  find_element: function(id) {
    return document.getElementById(id);
  },
  play_audio: function(sound) {
    var elem = soundGrabber.find_element(sound.get('id'));
    if(elem && elem.currentTime > 0 && !elem.paused) {
      sound.set('playing', false);
      elem.pause();
    } else if(elem) {
      sound.set('playing', true);
      elem.currentTime = 0;
      elem.addEventListener('ended', function() {
        sound.set('playing', false);
      });
      elem.addEventListener('paused', function() {
        sound.set('playing', false);
      });
      elem.play();
    }
  }
}).create();

var boardGrabber = EmberObject.extend({
  setup: function(button, controller) {
    this.controller = controller;
    this.button = button;
  },
  clear: function() {
    this.controller.set('foundBoards', null);
    this.controller.set('linkedBoardName', null);
    this.controller.set('pending_board', null);
    this.controller.set('confirm_found_board', null);
  },
  find_board: function() {
    var _this = this;
    var search_type = this.controller.get('board_search_type');
    this.controller.set('foundBoards', {term: this.controller.get('linkedBoardName'), ready: false});
    this.controller.set('confirm_found_board', null);
    var find_args =  {};
    var q = this.controller.get('linkedBoardName');
    if(search_type == 'personal') {
      find_args = {user_id: 'self', include_shared: true};
    } else if(search_type == 'personal_public') {
      find_args = {user_id: 'self', public: true, include_shared: true};
    } else if(search_type == 'current_user') {
      find_args = {user_id: this.controller.get('board.user_name'), include_shared: true };
    } else if(search_type == 'current_user_starred') {
      find_args = {user_id: this.controller.get('board.user_name'), starred: true };
    } else if(search_type == 'personal_starred') {
      find_args = {user_id: 'self', starred: true};
    } else if(search_type == 'personal_public_starred') {
      find_args = {user_id: 'self', starred: true, public: true };
    } else {
      find_args = {public: true};
    }
    var url_prefix = new RegExp("^" + location.protocol + "//" + location.host + "/");
    var key = (this.controller.get('linkedBoardName') || "").replace(url_prefix, "");
    var keyed_find = RSVP.resolve([]);
    if(key.match(/^[a-zA-Z0-9_-]+\/[a-zA-Z0-9_-]+|\d+_\d+$/) || key) {
      // right now this is always doing a double-lookup, first for an exact
      // match by key and then by query string. It'd be better if it were only
      // one lookup..
      var keyed_find_args = $.extend({}, find_args, {key: key});
      keyed_find = CoughDrop.store.query('board', keyed_find_args).then(null, function() { return RSVP.resolve([]); });
    }
    keyed_find.then(function(data) {
      var board = data.find(function() { return true; });
      if(!board || !_this.controller.get('linkedBoardName')) {
        find_args.q = q;
        CoughDrop.store.query('board', find_args).then(function(data) {
          _this.controller.set('foundBoards.ready', true);
          _this.controller.set('foundBoards.results', data);
        });
      } else {
        _this.pick_board(board);
      }
    }, function() { });
  },
  build_board: function() {
    var board = CoughDrop.store.createRecord('board', {
      name: this.controller.get('linkedBoardName'),
      copy_access: true,
      grid: {}
    });
    this.controller.set('confirm_found_board', null);
    var original_board = this.controller.get('board');
    if(original_board) {
      board.set('grid.rows', original_board.get('grid.rows') || 2);
      board.set('grid.columns', original_board.get('grid.columns') || 4);
    } else {
      board.set('grid.rows', 2);
      board.set('grid.columns', 4);
    }
    board.set('for_user_id', 'self');
    if(this.controller.get('supervisees')) {
      var sups = this.controller.get('supervisees');
      if(sups.length > 0) {
        var user_name = original_board.get('user_name');
        sups.forEach(function(sup) {
          if(sup.name == user_name) {
            board.set('for_user_id', sup.id);
          }
        });
      }
    }
    this.controller.set('pending_board', board);
  },
  cancel_build_board: function() {
    this.controller.set('pending_board', null);
  },
  create_board: function() {
    var board = this.controller.get('pending_board');
    if(board.get('copy_access')) {
      var original_board = this.controller.get('board');
      if(original_board) {
        board.set('license', original_board.get('license'));
        board.set('public', original_board.get('public'));
        board.set('visibility', original_board.get('visibility'));
      }
    }
    var _this = this;
    board.save().then(function(board) {
      _this.pick_board(board);
    }, function() { });
  },
  copy_found_board: function() {
    var _this = this;
    var board = _this.controller.get('confirm_found_board');
    if(!board) { return; }

    var source_board_user_name = _this.controller.get('board.user_name');
    var editable_supervisee_author = (app_state.get('currentUser.supervisees') || []).find(function(s) { return s.edit_permission && s.user_name == source_board_user_name; });
    var new_author = (editable_supervisee_author || {}).user_name || app_state.get('currentUser.user_name');

    board.set('copy_status', {copying: true});
    board.reload().then(function() {
      board.set('copy_status', {copying: true});
      CoughDrop.store.findRecord('user', new_author).then(function(user) {
        editManager.copy_board(board, 'copy_only', user).then(function(copy) {
          board.set('copy_status', null);
          _this.pick_board(copy, true);
        }, function(err) {
          board.set('copy_status', {error: true});
        });
      }, function() {
        board.set('copy_status', {error: true});
      });
    }, function() {
      board.set('copy_status', {error: true});
    });
  },
  pick_board: function(board, force) {
    var _this = this;
    var source_board_user_name = _this.controller.get('board.user_name');
    var linked_board_user_name = board.get('user_name');
    var current_user_name = app_state.get('currentUser.user_name');
    var editable_supervisee_author = (app_state.get('currentUser.supervisees') || []).find(function(s) { return s.edit_permission && s.user_name == source_board_user_name; });
    var can_copy_for_author = editable_supervisee_author || current_user_name == source_board_user_name;

    var confirm = false;
    if(can_copy_for_author && source_board_user_name != linked_board_user_name) {
      // if the current user is allowed to make copies for the edited board's author, ask for
      // confirmation and copy for the edited board's author
      confirm = true;
    } else if(!can_copy_for_author && source_board_user_name != linked_board_user_name && current_user_name != linked_board_user_name) {
      // if the current user is not allowed to make copies for the edited board's author,
      // only ask if the board matches neither the current user not the board author,
      // and then make the copy for the current user
      confirm = true;
    }
    if(confirm && !force) {
      board.set('copy_status', null);
      this.controller.set('confirm_found_board', board);
    } else {
      this.controller.set('confirm_found_board', null);
      editManager.change_button(this.controller.get('model.id'), {
        load_board: {
          id: board.id,
          key: board.get('key')
        }
      });
      this.clear();
    }
  },
  files_dropped: function(files) {
    var board = null;
    for(var idx = 0; idx < files.length; idx++) {
      if(!board && files[idx].name.match(/\.(obf|obz|csv)$/)) {
        board = files[idx];
      }
    }
    if(board) {
      boardGrabber.file_selected(board);
    } else {
      alert(i18n.t('no_board_found', "No valid board file found"));
    }
  },
  file_selected: function(board) {
    var data_uri = null;

    if(!board) {
      modal.close();
      modal.error(i18n.t('invalid_board_file', "Please select a valid board file (.obf, .obz, or .csv)"));
      return;
    }
    var generate_data_uri = contentGrabbers.read_file(board);

    var progressor = EmberObject.create();
    var error = modal.error;

    modal.open('importing-boards', progressor);

    var type = 'obf';
    if(board.name && board.name.match(/\.obz$/)) {
      type = 'obz';
    }
    else if(board.name && board.name.match(/\.csv$/)) {
      type = 'csv';
    }

    var progress = contentGrabbers.upload_for_processing(board, '/api/v1/boards/imports', {type: type}, progressor);

    progress.then(function(boards) {
      if(boards[0] && boards[0].key) {
        if(modal.is_open('importing-boards')) {
          boardGrabber.transitioner.transitionTo('board', boards[0].key);
        } else {
          modal.notice(i18n.t('boards_imported', "Board(s) successfully imported!"));
        }
      } else {
        if(modal.is_open('importing-boards')) {
          modal.close();
        }
        modal.error(i18n.t('upload_failed', "Upload failed"));
      }
    }, function() {
      if(modal.is_open('importing-boards')) {
        modal.close();
      }
      error(i18n.t('upload_failed', "Upload failed"));
    });
  }
}).create();

var linkGrabber = EmberObject.extend({
  setup: function(button, controller) {
    this.controller = controller;
    this.button = button;
  },
  clear: function() {
  },
  find_apps: function() {
    var _this = this;
    var os = this.controller.get('app_find_mode') || 'ios';
    var q = this.controller.get(os + '_app_name');
    this.controller.set('foundApps', {term: q, ready: false});
    if(os == 'ios' || os == 'android') {
      var lookup = persistence.ajax('/api/v1/search/apps?q=' + encodeURIComponent(q) + '&os=' + os, {
        type: 'GET'
      });

      return lookup.then(function(results) {
        _this.controller.set('foundApps.ready', true);
        _this.controller.set('foundApps.results', results);
      }, function() {
        _this.controller.set('foundApps.ready', true);
        _this.controller.set('foundApps.results', []);
      });
    } else {
      return RSVP.resolve([]);
    }
  },
  pick_app: function(app) {
    var os = this.controller.get('app_find_mode') || 'ios';
    if(!this.controller.get('model.apps')) {
      this.controller.set('model.apps', {web: {}});
    }
    this.controller.set('model.apps.' + os, app);
    this.controller.set('foundApps', null);
  },
  set_custom: function() {
    var os = this.controller.get('app_find_mode') || 'ios';
    if(this.controller.get('model.apps.' + os)) {
      this.controller.set('model.apps.' + os + '.custom', true);
    }
  },
  set_app_find_mode: function(mode) {
    this.controller.set('app_find_mode', mode);
    if(!this.controller.get('model.apps')) {
      this.controller.set('model.apps', {web: {}});
    }
    this.controller.set('foundApps', null);
  }
}).create();

document.addEventListener('dragover', function(event) {
  if(document.getElementById('find_picture')) {
    event.preventDefault();
  }
});
$(document).on('change', '#image_upload,#sound_upload,#board_upload,#avatar_upload,#video_upload,#badge_upload,#recording_upload', function(event) {
  var type = 'image';
  if(event.target.id == 'sound_upload') { type = 'sound'; }
  if(event.target.id == 'video_upload') { type = 'video'; }
  if(event.target.id == 'board_upload') { type = 'board'; }
  if(event.target.id == 'avatar_upload') { type = 'avatar'; }
  if(event.target.id == 'badge_upload') { type = 'badge'; }
  if(event.target.id == 'recording_upload') { type = 'recording'; }
  var files = event.target.files;
  contentGrabbers.file_selected(type, files);
}).on('paste', function(event) {
  if(document.getElementById('find_picture')) {
    event = event.originalEvent || event;
    var data = event && event.clipboardData && event.clipboardData.items;
    var found_file = false;
    if(data) {
      for(var idx = 0; idx < data.length; idx++) {
        if(data[idx] && data[idx].kind == 'file') {
          found_file = true;
        }
      }
    }
    if(found_file) {
      contentGrabbers.file_pasted('image', data);
      event.preventDefault();
      event.stopPropagation();
    }
  }
}).on('drop', function(event) {
  event.preventDefault();
  event.stopPropagation();
  if($(event.target).closest('.button').length > 0) {
    $('.button.drop_target').removeClass('drop_target');
    var id = $(this).attr('data-id');
    contentGrabbers.content_dropped(id, event.dataTransfer);
  } else if(document.getElementById('find_picture')) {
    if(pictureGrabber.controller.get('model.id')) {
      contentGrabbers.content_dropped(pictureGrabber.controller.get('model.id'), event.dataTransfer);
    }
  } else if($(event.target).closest('.board_drop').length > 0) {
    boardGrabber.files_dropped(event.dataTransfer.files);
  }
  event.stopPropagation();
}).on('keydown', '.form-horizontal', function(event) {
  if(event.keyCode == 32 && event.target.tagName == 'BUTTON') {
    if($(event.target).closest("#button_settings").length > 0) {
      if($("#recording_status").length > 0) {
        $("#recording_status").focus();
        event.preventDefault();
        soundGrabber.toggle_recording_sound();
      }
    }
  }
});

contentGrabbers.boardGrabber = boardGrabber;
contentGrabbers.soundGrabber = soundGrabber;
contentGrabbers.linkGrabber = linkGrabber;
contentGrabbers.pictureGrabber = pictureGrabber;
contentGrabbers.videoGrabber = videoGrabber;
window.cg = contentGrabbers;
export default contentGrabbers;
