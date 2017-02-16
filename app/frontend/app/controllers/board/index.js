import Ember from 'ember';
import boundClasses from '../../utils/bound_classes';
import word_suggestions from '../../utils/word_suggestions';
import editManager from '../../utils/edit_manager';
import CoughDrop from '../../app';
import app_state from '../../utils/app_state';
import stashes from '../../utils/_stashes';
import capabilities from '../../utils/capabilities';
import persistence from '../../utils/persistence';
import i18n from '../../utils/i18n';
import modal from '../../utils/modal';
import Button from '../../utils/button';
import frame_listener from '../../utils/frame_listener';

var cached_images = {};
var last_redraw = (new Date()).getTime();

export default Ember.Controller.extend({
  slideoutService: Ember.inject.service('slideout-service'),
  title: function() {
    var name = this.get('model.name');
    var title = "Board";
    if(name) {
      title = title + " - " + name;
    }
    return title;
  }.property('model.name'),
  ordered_buttons: null,
  processButtons: function() {
    boundClasses.add_rules(this.get('model.buttons'));
    this.computeHeight();
    if(this.get('model.word_suggestions')) {
      var _this = this;
      _this.set('suggestions', {loading: true});
      word_suggestions.load().then(function() {
        _this.set('suggestions', {ready: true});
        _this.updateSuggestions();
      }, function() {
        _this.set('suggestions', {error: true});
      });
    }
    editManager.process_for_displaying();
  }.observes('app_state.board_reload_key'),
  check_for_share_approval: function() {
    var board_id = this.get('model.id');
    var _this = this;
    if(board_id && app_state.get('currentBoardState')) {
      var shares = (app_state.get('currentUser.pending_board_shares') || []);
      var matching_shares = shares.filter(function(s) { return s.board_id && s.board_id == board_id; });
      if(matching_shares.length > 0) {
        if(app_state.get('default_mode')) {
          var already = {}; //this.get('already_checked_boards') || {};
          if(!already[board_id]) {
            already[board_id] = true;
            this.set('already_checked_boards', already);
            modal.open('approve-board-share', {board: _this.get('model'), shares: matching_shares});
          }
        }
      }
    }
  }.observes('model.id', 'app_state.currentUser.pending_board_shares', 'app_state.default_mode'),
  updateSuggestions: function() {
    if(!this.get('model.word_suggestions')) { return; }
    var _this = this;

    var button_list = this.get('app_state.button_list');
    var last_button = button_list[button_list.length - 1];
    var current_button = null;
    if(last_button && last_button.in_progress) {
      current_button = last_button;
      last_button = button_list[button_list.length - 2];
    }
    var last_finished_word = ((last_button && (last_button.vocalization || last_button.label)) || "").toLowerCase();
    var word_in_progress = ((current_button && (current_button.vocalization || current_button.label)) || "").toLowerCase();

    word_suggestions.lookup({
      last_finished_word: last_finished_word,
      word_in_progress: word_in_progress,
      button_set: this.get('model.button_set'),
      board_id: this.get('model.id')
    }).then(function(result) {
      _this.set('suggestions.list', result);
    }, function() {
      _this.set('suggestions.list', []);
    });
  }.observes('app_state.button_list', 'app_state.button_list.[]', 'app_state.currentUser'),
  saveButtonChanges: function(decision) {
    var state = editManager.process_for_saving();

    if(this.get('model.license')) {
      this.set('model.license.copyright_notice_url', CoughDrop.licenseOptions.license_url(this.get('model.license.type')));
    }

    this.set('model.buttons', state.buttons);
    this.set('model.grid', state.grid);
    boundClasses.setup(true);
    this.processButtons();

    if(app_state.get('currentBoardState.id') && stashes.get('copy_on_save') == app_state.get('currentBoardState.id')) {
      app_state.controller.send('tweakBoard');
      return;
    }
    app_state.toggle_mode('edit');

    var board = this.get('model');
    board.save().then(null, function(err) {
      console.error(err);
      modal.error(i18n.t('board_save_failed', "Failed to save board"));
    });

    // TODO: on commit, only send attributes that have changed
    // to prevent stepping on other edits if all you're doing is
    // updating the name, for example. Side note: this is one
    // of the things that stresses me out about ember-data, changes
    // made out from underneath without you knowing. It happened
    // before, but with all the local caching it's more likely to
    // happen more often.
  },
  height: 400,
  computeHeight: function() {
    var height = window.innerHeight;
    var width = window.innerWidth;
    if(app_state.get('sidebar_pinned')) {
      width = width - 100; // TODO: make sidebar size configurable, or have it match top bar
    }
    this.set('window_inner_width', window.innerWidth);
    app_state.set('window_inner_width', window.innerWidth);
    var show_description = !app_state.get('edit_mode') && !app_state.get('speak_mode') && this.get('long_description');
    var topHeight = app_state.get('header_height') + 5;
    var sidebarTopHeight = topHeight;
    this.set('show_word_suggestions', this.get('model.word_suggestions') && app_state.get('speak_mode'));
    if(this.get('show_word_suggestions')) {
      topHeight = topHeight + 55;
      var style = this.get('get_style');
      var position = this.get('text_position');
      if(style == 'text_small') { topHeight = topHeight - 4; }
      else if(style == 'text_large') { topHeight = topHeight + 4; }
      else if(style == 'text_huge') { topHeight = topHeight + 17; }
      if(this.get('app_state.currentUser.preferences.word_suggestion_images') !== false && position != 'text_only') {
        topHeight = topHeight + 50;
        this.set('show_word_suggestion_images', true);
      }
    }
    if((!this.get('model.public') || this.get('model.license.type') != 'private') && !app_state.get('edit_mode') && !app_state.get('speak_mode')) {
      show_description = show_description || this.get('model.name');
      if(!this.get('model.public')) {
        if(this.get('model.protected_material')) {
          show_description = show_description + " - protected";
        } else {
          show_description = show_description + " - private";
        }
      }
    }
    if(show_description) {
      topHeight = topHeight + 30;
    }
    if(app_state.controller) {
      app_state.controller.set('sidebar_style', new Ember.String.htmlSafe("height: " + (height - sidebarTopHeight + 20) + "px;"));
    }
    this.setProperties({
      'height': height - topHeight,
      'width': width,
      'teaser_description': show_description
    });
  }.observes('app_state.speak_mode', 'app_state.edit_mode', 'model.word_suggestions', 'model.description', 'model.protected_material', 'app_state.sidebar_pinned', 'app_state.currentUser.preferences.word_suggestion_images', 'text_position'),
  board_style: function() {
    // Position the board at the correct height with regard to the header, and also
    // give it a white background (TODO check if this can be set by preferences otherwise)
    // so that slideout animation functions properly.
    return new Ember.String.htmlSafe("position: relative; height: " + (this.get('height') + 5) + "px;" +
      "background-color: white");
  }.property('height'),
  redraw_if_needed: function() {
    var now = (new Date()).getTime();
    if(now - last_redraw > 100) {
      this.redraw();
    }
  },
  redraw: function(klass, change, redraw_button_id) {
    var foundy = Math.round(10 * Math.random());
    var draw_id = redraw_button_id ? this.get('last_draw_id') : Math.random();
    this.set('last_draw_id', draw_id);
    var grid = this.get('current_grid');
    if(!grid) {
      return;
    }
    last_redraw = (new Date()).getTime();

    var starting_height = Math.floor((this.get('height') / (grid.rows || 2)) * 100) / 100;
    var starting_width = Math.floor((this.get('width') / (grid.columns || 2)) * 100) / 100;
    var extra_pad = this.get('extra_pad');
    var inner_pad = this.get('inner_pad');
    var double_pad = inner_pad * 2;
    var radius = 4;
    var context = null;

    var currentLabelHeight = this.get('base_text_height') - 3;
    this.set('model.text_size', 'normal');
    if(starting_height < 35) {
      this.set('model.text_size', 'really_small_text');
    } else if(starting_height < 75) {
      this.set('model.text_size', 'small_text');
    }

    var $canvas = Ember.$("#board_canvas");
    // TODO: I commented out the canvas element because, while it was a few
    // seconds faster rendering a large board, it also causes a lot of headaches with
    // things like tabindex, edit mode, switch access, etc.
    if($canvas[0]) {
      if(parseInt($canvas.attr('width'), 10) != this.get('width') * 3) {
        $canvas.attr('width', this.get('width') * 3);
      }
      if(parseInt($canvas.attr('height'), 10) != this.get('height') * 3) {
        $canvas.attr('height', this.get('height') * 3);
      }
      $canvas.css({width: this.get('width'), height: this.get('height')});
      context = $canvas[0].getContext('2d');
      var width = $canvas[0].width;
      var height = $canvas[0].height;
      if(!redraw_button_id) {
        context.clearRect(0, 0, width, height);
      }
    }


    var _this = this;
    var stretchable = !app_state.get('edit_mode') && app_state.get('currentUser.preferences.stretch_buttons') && app_state.get('currentUser.preferences.stretch_buttons') != 'none'; // not edit mode and user-enabled
    var buttons = this.get('ordered_buttons');
    var ob = this.get('ordered_buttons');

    var img_checker = function(url, callback) {
      if(cached_images[url]) {
        callback(cached_images[url]);
      } else {
        var img = new Image();
        img.draw_id = draw_id;
        img.src = url;
        img.onload = function() {
          cached_images[url] = img;
          if(_this.get('last_draw_id') == img.draw_id) {
            callback(img);
          }
        };
      }
    };
    var directions = function(ob, i, j) {
      var res = {};
      res.up = ob[i - 1] && ob[i - 1][j] && ob[i - 1][j].get('empty_or_hidden');
      res.upleft = ob[i - 1] && ob[i - 1][j - 1] && ob[i - 1][j - 1].get('empty_or_hidden');
      res.left = ob[i][j - 1] && ob[i][j - 1].get('empty_or_hidden');
      res.right = ob[i][j + 1] && ob[i][j + 1].get('empty_or_hidden');
      res.upright = ob[i - 1] && ob[i - 1][j + 1] && ob[i - 1][j + 1].get('empty_or_hidden');
      res.down = ob[i + 1] && ob[i + 1][j] && ob[i + 1][j].get('empty_or_hidden');
      res.downleft = ob[i + 1] && ob[i + 1][j - 1] && ob[i + 1][j - 1].get('empty_or_hidden');
      res.downright = ob[i + 1] && ob[i + 1][j + 1] && ob[i + 1][j + 1].get('empty_or_hidden');
      return res;
    };


    ob.forEach(function(row, i) {
      row.forEach(function(button, j) {
        var button_height = starting_height - (extra_pad * 2);
        if(button_height > 30) {
          button_height = button_height;
        }
        var button_width = starting_width - (extra_pad * 2);
        if(button_width > 30) {
          button_width = button_width;
        }
        var top = extra_pad + (i * starting_height) + inner_pad;
        var left = extra_pad + (j * starting_width) + inner_pad;

        if(stretchable) {
          var can_go = directions(ob, i, j);
          var went_up = false;
          var went_left = false;
          if(can_go.up) {
            if(stretchable == 'prefer_tall' || (can_go.upleft && can_go.upright)) {
              top = top - (extra_pad + (button_height / 2));
              button_height = button_height + extra_pad + (button_height / 2);
              went_up = true;
              var upper_can_go = directions(ob, i - 1, j);
              if(upper_can_go.up !== false && stretchable == 'prefer_tall' && !can_go.upright && !can_go.upleft) {
                top = top - (extra_pad + (button_height / 2)) + (starting_height / 4);
                button_height = button_height + extra_pad + (button_height / 2) - (starting_height / 4);
              }
            }
          }
          if(can_go.down) {
            if(stretchable == 'prefer_tall' || (can_go.downleft && can_go.downright)) {
              button_height = button_height + extra_pad + (button_height / 2);
              if(went_up) {
                button_height = button_height - (starting_height / 4);
              }
              var lower_can_go = directions(ob, i + 1, j);
              if(lower_can_go.down !== false && stretchable == 'prefer_tall' && !can_go.downright && !can_go.downleft) {
                button_height = button_height + extra_pad + (button_height / 2) - (starting_height / 4);
              }
            }
          }
          if(can_go.left) {
            if(stretchable == 'prefer_wide' || (can_go.upleft && can_go.downleft)) {
              left = left - (extra_pad + (button_width / 2));
              button_width = button_width + extra_pad + (button_width / 2);
              went_left = true;
              var lefter_can_go = directions(ob, i, j - 1);
              if(lefter_can_go.left !== false && stretchable == 'prefer_wide' && !can_go.upleft && !can_go.downleft) {
                left = left - (extra_pad + (button_width / 2)) + (starting_width / 4);
                button_width = button_width + extra_pad + (button_width / 2) - (starting_width / 4);
              }
            }
          }
          if(can_go.right) {
            if(stretchable == 'prefer_wide' || (can_go.upright && can_go.downright)) {
              button_width = button_width + extra_pad + (button_width / 2);
              if(went_left) {
                button_width = button_width - (starting_width / 4);
              }
              var righter_can_go = directions(ob, i, j + 1);
              if(righter_can_go.right !== false && stretchable == 'prefer_wide' && !can_go.upright && !can_go.downright) {
                button_width = button_width + extra_pad + (button_width / 2) - (starting_width / 4);
              }
            }
          }
        }
        var image_height = button_height - currentLabelHeight - CoughDrop.boxPad - (inner_pad * 2) + 8;
        var image_width = button_width - CoughDrop.boxPad - (inner_pad * 2) + 8;

        var top_margin = currentLabelHeight + CoughDrop.labelHeight - 8;
        if(_this.get('model.text_size') == 'really_small_text') {
          if(currentLabelHeight > 0) {
            image_height = image_height + currentLabelHeight - CoughDrop.labelHeight + 25;
            top_margin = 0;
          }
        } else if(_this.get('model.text_size') == 'small_text') {
          if(currentLabelHeight > 0) {
            image_height = image_height + currentLabelHeight - CoughDrop.labelHeight + 10;
            top_margin = top_margin - 10;
          }
        }
        if(button_height < 50) {
          image_height = image_height + (inner_pad * 2);
        }
        if(button_width < 50) {
          image_width = image_width + (inner_pad * 2) + (extra_pad * 2);
        }
        if(currentLabelHeight === 0 || _this.get('text_position') != 'text_position_top') {
          top_margin = 0;
        }

        button.set('positioning', {
          top: top,
          left: left - inner_pad - inner_pad - inner_pad,
          width: button_width,
          height: button_height,
          image_height: image_height,
          image_width: image_width,
          image_square: Math.min(image_height, image_width),
          image_top_margin: top_margin,
          border: inner_pad
        });

        if(context) {
          if(!button.get('empty_or_hidden') && (!redraw_button_id || redraw_button_id == button.id)) {
            var image_left = (button_width - image_height) / 2 - inner_pad;
            var image_top = inner_pad + 2;
            var text_top = image_height + image_top + 3;

            var w = (button_width - double_pad) * 3 + 3.5; // FIX: added 3.5 here
            var h = (button_height - double_pad) * 3 + 2; // FIX: added 2 here
            var x = left * 3 - 1.5; // FIX: minused 1.5 here
            var y = top * 3 + 8; // FIX: added 8 here to make it work
            var r = radius * 3 ;

            if(redraw_button_id) {
              context.clearRect(x - 9, y - 9, w + 18, h + 18);
            }

            context.beginPath();
            context.strokeStyle = button.get('border_color') || '#ccc';
            context.fillStyle = button.get('background_color') || '#fff';
            context.lineWidth = 3;
            var extra = 0;
            if(button.get('touched')) {
              context.fillStyle = button.get('dark_background_color');
              context.strokeStyle = button.get('dark_border_color');
              context.lineWidth = 9;
              extra = 3;
            } else if(button.get('hover')) {
              console.log(button.get('dark_background_color'));
              context.fillStyle = button.get('dark_background_color');
              context.strokeStyle = button.get('dark_border_color');
              context.lineWidth = 6;
              extra = 3;
            }

            context.moveTo(x + r - extra, y - extra);
            context.lineTo(x + w - r + extra, y - extra);
            context.quadraticCurveTo(x + w + extra, y - extra, x + w + extra, y + r - extra);
            context.lineTo(x + w + extra, y + h - r + extra);
            context.quadraticCurveTo(x + w + extra, y + h + extra, x + w - r + extra, y + h + extra);
            context.lineTo(x + r - extra, y + h + extra);
            context.quadraticCurveTo(x - extra, y + h + extra, x - extra, y + h - r + extra);
            context.lineTo(x - extra, y + r - extra);
            context.quadraticCurveTo(x - extra, y - extra, x + r - extra, y - extra);
            context.closePath();

    //           context.rect(left * 3, top * 3, width * 3, height * 3);
            if(foundy == j) {
  //            context.fillStyle = 'rgb(255, 255, 170)';
            }
            context.fill();
            context.stroke();
            context.lineWidth = 3;

            context.save();
            context.textAlign = 'center';
            context.textBaseline = 'top';
            context.font = "36px serif";
            context.rect(left * 3, (top + text_top) * 3, button_width * 3, 60);
            context.clip();

            context.fillStyle = button.get('text_color') || '#000';
            context.fillText(button.get('label'), (left + (button_width / 2) - inner_pad) * 3, (top + text_top) * 3 - 8); //FIX: minused 8

            context.restore();

            context.beginPath();
            context.rect((left + image_left) * 3, (top + image_top) * 3, image_height * 3, image_height * 3);
            context.fillStyle = '#fff';
            context.closePath();
            context.fill();

            var draw_action = function() {
              if(button.get('action_image') && !button.get('talkAction')) {
                img_checker(button.get('action_image'), function(img) {
                  context.drawImage(img, x + w - 60 - 6, y, 60, 60);
                });
              }
            };
            draw_action();

            var url = button.get('image.best_url');
            img_checker(url, function(img) {
              // TODO: proportionally-fit centered in square area
              context.drawImage(img, (left + image_left) * 3 - 1, (top + image_top) * 3 + 3, image_height * 3 + 1.5, image_height * 3); // FIX: added 2 here
              draw_action();
            });
          }
        }
      });
    });
    app_state.set('board_virtual_dom.ordered_buttons', ob);
    app_state.align_button_list();
  }.observes('model.id', 'extra_pad', 'inner_pad', 'base_text_height', 'text_style', 'text_position', 'ordered_buttons', 'border_style', 'height', 'width', 'app_state.edit_mode', 'nothing_visible', 'app_state.currentUser.preferences.stretch_buttons'),
  long_description: function() {
    var desc = "";
    if(this.get('model.name') && this.get('model.name') != 'Unnamed Board') {
      desc = this.get('model.name');
      if(this.get('model.description')) {
        desc = desc + " - ";
      }
    }
    if(this.get('model.description')) {
      desc = desc + this.get('model.description');
    }
    return desc;
  }.property('model.description', 'model.name'),
  cc_license: function() {
    return (this.get('model.license.type') || "").match(/^CC\s/);
  }.property('model.license.type'),
  pd_license: function() {
    return this.get('model.license.type') == 'public domain';
  }.property('model.license.type'),
  starImage: function() {
    var prefix = capabilities.browserless ? "" : "/";
    return prefix + (this.get('model.starred') ? 'images/star.png' : 'images/star_gray.png');
  }.property('model.starred'),
  starAlt: function() {
    return this.get('model.starred') ? i18n.t('already_starred', "Already liked") : i18n.t('star_this_board', "Like this board");
  }.property('model.starred'),
  noUndo: true,
  noRedo: true,
  paint_mode: false,
  paintColor: function() {
    var mode = this.get('paint_mode');
    if(mode) {
      if(mode.hidden === true) {
        return "<span class='glyphicon glyphicon-minus-sign'></span>";
      } else if(mode.hidden === false) {
        return "<span class='glyphicon glyphicon-ok-sign'></span>";
      } else if(mode.close_link === true) {
        return "<span class='glyphicon glyphicon-remove-sign'></span>";
      } else if(mode.close_link === false) {
        return "<span class='glyphicon glyphicon-plus-sign'></span>";
      } else {
        return "<span class='swatch' style='width: 14px; height: 14px; border-color: " + mode.border + "; background-color: " + mode.fill + ";'></span>";
      }
    } else {
      return '';
    }
  }.property('paint_mode'),
  current_grid: function() {
    var ob = this.get('ordered_buttons');
    if(!ob) { return null; }
    return {
      rows: ob.length,
      columns: ob[0].length
    };
  }.property('ordered_buttons'),
  extra_pad: function() {
    var spacing = app_state.get('currentUser.preferences.device.button_spacing') || window.user_preferences.device.button_spacing;
    if(spacing == 'none') {
      return 0;
    } else if(spacing == 'minimal' || app_state.get('window_inner_width') < 600) {
      return 1;
    } else if(spacing == "extra-small" || app_state.get('window_inner_width') < 750) {
      return 2;
    } else if(spacing == "medium") {
      return 10;
    } else if(spacing == "large") {
      return 20;
    } else if(spacing == "huge") {
      return 45;
    } else {
      return 5;
    }
  }.property('app_state.currentUser.preferences.device.button_spacing', 'app_state.window_inner_width'),
  inner_pad: function() {
    var spacing = app_state.get('currentUser.preferences.device.button_border') || window.user_preferences.device.button_border;
    if(spacing == "none") {
      return 0;
    } else if(app_state.get('window_inner_width') < 600) {
      return 1;
    } else if(spacing == "medium" || app_state.get('window_inner_width') < 750) {
      return 2;
    } else if(spacing == "large") {
      return 5;
    } else if(spacing == "huge") {
      return 10;
    } else {
      return 1;
    }
  }.property('app_state.currentUser.preferences.device.button_border', 'window_inner_width'),
  base_text_height: function() {
    var text = app_state.get('currentUser.preferences.device.button_text') || window.user_preferences.device.button_text;
    var position = app_state.get('currentUser.preferences.device.button_text_position') || window.user_preferences.device.button_text_position;
    if(text == "small") {
      return 14;
    } else if(text == "none" || position == "none") {
      return 0;
    } else if(text == "large") {
      return 22;
    } else if(text == "huge") {
      return 35;
    } else {
      return 18;
    }
  }.property('app_state.currentUser.preferences.device.button_text', 'app_state.currentUser.preferences.device.button_text'),
  text_style: function() {
    var size = app_state.get('currentUser.preferences.device.button_text') || window.user_preferences.device.button_text;
    if(app_state.get('currentUser.preferences.device.button_text_position') == 'none') {
      size = 'none';
    }
    if(size != 'none') {
      if(app_state.get('window_inner_width') < 600) {
        size = 'small';
      } else if(app_state.get('window_inner_width') < 750 && size != 'small') {
        size = 'medium';
      }
    }
    return "text_" + size;
  }.property('app_state.currentUser.preferences.device.button_text', 'app_state.currentUser.preferences.device.button_text_position'),
  text_position: function() {
    return "text_position_" + (app_state.get('currentUser.preferences.device.button_text_position') || window.user_preferences.device.button_text_position);
  }.property('app_state.currentUser.preferences.device.button_text_position'),
  border_style: function() {
    var spacing = app_state.get('currentUser.preferences.device.button_border') || window.user_preferences.device.button_border;
    return "border_" + spacing;
  }.property('app_state.currentUser.preferences.device.button_border'),
  button_style: function() {
    return app_state.get('currentUser.preferences.device.button_style');
  }.property('app_state.currentUser.preferences.device.button_style'),
  editModeNormalText: function() {
    return app_state.get('edit_mode') && this.get('model.text_size') != 'really_small_text';
  }.property('app_state.edit_mode', 'model.text_size'),
  nothing_visible_not_edit: function() {
    return this.get('nothing_visible') && !app_state.get('edit_mode');
  }.property('nothing_visible', 'app_state.edit_mode'),
  display_class: function() {
    var res = "board advanced_selection ";
    if(this.get('model.finding_target')) {
      res = res + "finding_target ";
    }
    if(this.get('stashes.current_mode')) {
      res = res + this.get('stashes.current_mode')  + " ";
    }
    if(this.get('stashes.all_buttons_enabled')) {
      res = res + 'show_all_buttons ';
    } else if(app_state.get('currentUser.preferences.hidden_buttons') == 'hint') {
      res = res + 'hint_hidden_buttons ';
    } else if(app_state.get('currentUser.preferences.hidden_buttons') == 'grid') {
      res = res + 'grid_hidden_buttons ';
    }
    if(app_state.get('currentUser.hide_symbols')) {
      res = res + 'show_labels ';
    }
    if(this.get('paint_mode')) {
      res = res + "paint ";
    }
    if(this.get('border_style')) {
      res = res + this.get('border_style') + " ";
    }
    if(this.get('text_style')) {
      res = res + this.get('text_style') + " ";
    }
    if(this.get('text_position')) {
      res = res + this.get('text_position') + " ";
    }
    if(this.get('button_style')) {
      var style = Button.style(this.get('button_style'));
      if(style.upper) {
        res = res + "upper ";
      } else if(style.lower) {
        res = res + "lower ";
      }
      if(style.font_class) {
        res = res + style.font_class + " ";
      }
    }
    return res;
  }.property('stashes.all_buttons_enabled', 'stashes.current_mode', 'paint_mode', 'border_style', 'text_style', 'model.finding_target', 'app_state.currentUser.preferences.hidden_buttons', 'app_state.currentUser.hide_symbols'),
  suggestion_class: function() {
    var res = "advanced_selection ";
    if(this.get('text_style')) {
      res = res + this.get('text_style') + " ";
    }
    if(this.get('text_position')) {
      res = res + this.get('text_position') + " ";
    }
    if(this.get('button_style')) {
      var style = Button.style(this.get('button_style'));
      if(style.upper) {
        res = res + "upper ";
      } else if(style.lower) {
        res = res + "lower ";
      }
      if(style.font_class) {
        res = res + style.font_class + " ";
      }
    }
    res = res + this.get('text_style') + " ";
    return res;
  }.property('text_style', 'button_style', 'text_style'),
  button_symbol_class: function() {
    var res = "button-label-holder ";
    if(this.get('app_state.currentUser.hide_symbols')) {
      res = res + "no_image ";
    }
    if(this.get('app_state.currentUser.preferences.device.button_text_position') == 'top') {
      res = res + "top ";
    }
    return res;
  }.property('app_state.currentUser.hide_symbols', 'app_state.currentUser.preferences.device.button_text_position'),
  reload_on_connect: function() {
    if(persistence.get('online') && !this.get('model.id')) {
      var _this = this;
      var obj = this.store.findRecord('board', this.get('model.id') || this.get('model.key'));
      return obj.then(function(data) {
        _this.set('model', data);
      }, function() { });
    }
  }.observes('persistence.online'),
  // Add a button with the given label to the next available empty space on the board.
  // TODO: But if rearranging is prefered, will be next in order after others, there
  // will be no spaces between consecutive buttons.
  add_next_button_by_label: function(label) {
    editManager.add_button_at_next_empty(label);
  },
  // Remove button, and if rearrange, remove all empty spaces
  // TODO determine behavior on add.
  remove_button_by_preferred_method: function(buttonId) {
    this.actions.clear_button(buttonId);
    if(this.get('rearrangeButtons')) {
      editManager.remove_empty_holes();
    }
  },
  // Sets whether user wants to rearrange buttons on edit or not.
  // If yes, rearrange to remove empty spots if necessary
  setRearrangeButtons: function(preference) {
    this.set('rearrangeButtons', preference); 
    if (preference) {
      editManager.remove_empty_holes();
    }
  },
  // Handles subscriptions to incoming events regarding he board editor slideout
  // through the slideoutService. Currently handles removing a button based on the
  // label indicated to remove in the slideout.
  subscribeToService: Ember.on('init', function() {
    this.get('slideoutService').on('slideoutRemoveButton', this, this.remove_button_by_preferred_method);
    this.get('slideoutService').on('slideoutAddButton', this, this.add_next_button_by_label);
    this.get('slideoutService').on('setRearrangeButtonsPreference', this, this.setRearrangeButtons);
  }),
  unsubscribeToService: Ember.on('willDestroy', function () {
    this.get('slideoutService').off('slideoutRemoveButton', this, this.remove_button_by_preferred_method);
    this.get('slideoutService').off('slideoutAddButton', this, this.add_next_button_by_label);
    this.get('slideoutService').off('setRearrangeButtonsPreference', this, this.setRearrangeButtons);
  }),
  actions: {
    boardDetails: function() {
      modal.open('board-details', {board: this.get('model')});
    },
    buttonSelect: function(id, event) {
      var controller = this;
      var board = this.get('model');
      if(app_state.get('edit_mode')) {
        if(editManager.finding_target()) {
          editManager.apply_to_target(id);
        } else {
          if(typeof(event) != 'string') {
            event = null;
          }
          var button = editManager.find_button(id);
          button.state = event || 'general';
          modal.open('button-settings', {button: button, board: board});
        }
      } else {
        var button = editManager.find_button(id); //(board.get('buttons') || []).find(function(b) { return b.id == id; });
        if(!button) { return; }
        var app = app_state.controller;
        button.findContentLocally().then(function() {
          app.activateButton(button, {image: button.get('image'), sound: button.get('sound'), board: board, event: event});
        }, function() { });
      }
    },
    buttonPaint: function(id) {
      editManager.paint_button(id);
    },
    complete_word: function(word) {
      var text = word.word;
      var button = editManager.fake_button();
      button.label = ":complete";
      button.completion = text;
      button.image = word.original_image;

      var controller = this;
      var board = this.get('model');
      var app = app_state.controller;
      app.activateButton(button, {board: board});
    },
    symbolSelect: function(id) {
      var board = this;
      if(!app_state.get('edit_mode')) { return; }
      var button = editManager.find_button(id);
      button.state = 'picture';
      modal.open('button-settings', {button: button, board: this.get('model')});
    },
    actionSelect: function(id) {
      var board = this;
      if(!app_state.get('edit_mode')) { return; }
      var button = editManager.find_button(id);
      button.state = 'action';
      modal.open('button-settings', {button: button, board: this.get('model')});
    },
    rearrangeButtons: function(dragId, dropId) {
      editManager.switch_buttons(dragId, dropId);
    },
    // Empties the contents of a button.
    clear_button: function(id) {
      editManager.clear_button(id);
    },
    stash_button: function(id) {
      editManager.stash_button(id || editManager.stashed_button_id);
      modal.success(i18n.t('button_stashed', "Button stashed!"));
      var $stash_hover = Ember.$("#stash_hover");
      $stash_hover.removeClass('on_button').data('button_id', null);
    },
    toggleEditMode: function() {
      app_state.toggle_edit_mode();
    },
    compute_height: function(force) {
      this.computeHeight(force);
    },
    redraw: function(id) {
      this.redraw(this, 'redraw_button', id);
    },
    button_event: function(action, a, b) {
      this.send(action, a, b);
    }
  }
});
