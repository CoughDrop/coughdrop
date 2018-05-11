import Ember from 'ember';
import modal from '../../utils/modal';
import app_state from '../../utils/app_state';
import i18n from '../../utils/i18n';
import {set as emberSet, get as emberGet} from '@ember/object';
import { later as runLater } from '@ember/runloop';

export default modal.ModalController.extend({
  opening: function() {
    var users = this.get('model.users');
    var user = app_state.get('currentUser');
    var _this = this;
    _this.set('activity_index', 0);

    var today = (new Date());
    var now = today.getTime();
    var weekhour = ((new Date()).getDay() * 24) + (new Date()).getHours();

    var date = today;
    date.setHours(0, 0, 0, 0);
    // Thursday in current week decides the year.
    date.setDate(date.getDate() + 3 - (date.getDay() + 6) % 7);
    // January 4 is always in week 1.
    var week1 = new Date(date.getFullYear(), 0, 4);
    // Adjust to Thursday in week 1 and count number of weeks from date to week1.
    var weeknum = 1 + Math.round(((date.getTime() - week1.getTime()) / 86400000
                          - 3 + (week1.getDay() + 6) % 7) / 7);

    // We increment weekhour by week number to prevent getting the same suggestions
    // Every week at the same time of the week.
    weekhour = weekhour + weeknum;

    // If opened less than five minutes since last time, keep the previous weekhour
    // Otherwise just use the current weekhour, whatever it may be
    if(_this.get('last_opening') && (now - _this.get('last_opening') < (5 * 1000 * 60))) {
      _this.set('weekhour', _this.get('last_weekhour') || weekhour);
    } else {
      _this.set('weekhour', weekhour);
    }
    _this.set('last_weekhour', _this.get('weekhour'));
    _this.set('last_opening', now);


    _this.set('show_target_words', false);
    _this.set('force_intro', false);
    if(user) {
      _this.set('activities', {loading: true});
      user.load_word_activities().then(function(activities) {
        _this.set('activities', activities);
      }, function(err) {
        _this.set('activities', {error: true});
      });
    } else {
      _this.set('activities', {error: true});
    }
  },
  user_activities: function() {
    var res = [];

    var empty_num = 0;
    if(this.get('force_intro') || !app_state.get('currentUser.preferences.progress.modeling_ideas_viewed')) {
      res.push({intro: true});
      empty_num++;
    }

    var user_ids = (this.get('model.users') || []).mapBy('id');
    var middles = [];
    (this.get('activities.list') || []).forEach(function(a) {
      emberSet(a, 'real', true);
      var types = {};
      types[a.type] = true;
      emberSet(a, 'types', types);
      var valids = 0;
      a.user_ids.forEach(function(id) { if(user_ids.indexOf(id) !== -1) { valids++; } });
      if(valids > 0 && res.length < (5 + empty_num)) {
        if(user_ids.length > 1) {
          emberSet(a, 'matching_users', valids);
        }
        middles.push(a);
      }
    });
    if(middles.length > 0 && !app_state.get('currentUser.preferences.progress.modeling_ideas_target_words_reviewed')) {
      res.push({target_words: true});
      empty_num++;
    }

    var weekhour = this.get('weekhour');
    var units = 3;
    var chunks = Math.max(1, Math.floor(middles.length / units));
    // with 25 records:
    // total chunks: 8
    // 0 => 0-4, 1 => 6-10, 2 => 12-16, 3 => 18-22, 4 => 3-7, 5 => 9-13, 6 => 15-19, 7 => 21-25
    // with 2 records:
    // total chunks: 1
    // 0 => 0-2
    // with 27 records:
    // total chunks: 9
    // 0 => 0-4, 1 => 6-10, 2 => 12-16, 3 => 18-22, 4 => 24-27, 5 => 3-7, 6 => 9-13, 7 => 15-19, 8 => 21-25
    var index = weekhour % chunks;
    var cutoff_chunk = Math.floor(chunks / 2);
    var offset = index * units * 2
    if(index > 0 && index >= cutoff_chunk) {
      offset = ((index - cutoff_chunk) * units * 2) + units;
    }
    middles = middles.slice(offset, offset + 5);
    res = res.concat(middles);

    if(res.length == empty_num) {
      var none_premium = true;
      (this.get('model.users') || []).forEach(function(u) { if(emberGet(u, 'premium')) { none_premium = false; } });
      if(none_premium) {
        res.push({none_premium: true});
      } else {
        res.push({empty: true});
      }
    }
    return res;
  }.property('activities', 'model.users', 'force_intro'),
  user_words: function() {
    var res = [];
    var text_reasons = {
      fallback: i18n.t('starter_word', "Starter Word"),
      primary_words: i18n.t('goal_words', "Goal Target"),
      primary_modeled_words: i18n.t('goal_words', "Goal Target"),
      secondary_words: i18n.t('goal_words', "Goal Target"),
      secondary_modeled_words: i18n.t('goal_words', "Goal Target"),
      popular_modeled_words: i18n.t('modeled_words', "Frequently-Modeled"),
      infrequent_core_words: i18n.t('infrequent_core', "Rarely-Used Core"),
      emergent_words: i18n.t('emergent', "Emergent Use"),
      dwindling_words: i18n.t('dwindling', "Dwindling Use"),
      infrequent_home_words: i18n.t('infrequence_home', "Rare but on Home Board")
    };
    var user_ids = (this.get('model.users') || []).mapBy('id');
    (this.get('activities.words') || []).forEach(function(w) {
      var valids = 0;
      w.user_ids.forEach(function(id) { if(user_ids.indexOf(id) !== -1) { valids++; } });
      if(valids > 0) {
        if(user_ids.length > 1) {
          emberSet(w, 'matching_users', valids);
        }
        emberSet(w, 'text_reasons', w.reasons.map(function(r) { return text_reasons[r]; }).uniq().compact().join(', '));
        res.push(w);
      }
    });
    return res;
  }.property('activities', 'model.users'),
  words_list: function() {
    return (this.get('user_words') || []).mapBy('word').join(', ');
  }.property('user_words'),
  current_activity: function() {
    var idx = this.get('activity_index') || 0;
    var res = (this.get('user_activities') || [])[idx];
    if(res && emberGet(res, 'image.image_url')) {
      var img = emberGet(res, 'image.image_url');
      emberSet(res, 'image.image_url', Ember.templateHelpers.path('images/blank.gif'));
      runLater(function() {
        emberSet(res, 'image.image_url', img);
      });
    }
    return res;
  }.property('activity_index', 'user_activities'),
  no_next: function() {
    return !((this.get('activity_index') + 1) < this.get('user_activities.length'));
  }.property('activity_index', 'user_activities'),
  no_previous: function() {
    return !!(this.get('activity_index') == 0 || this.get('user_activities.length') == 0 || !this.get('user_activities.length'));
  }.property('activity_index', 'user_activities'),
  actions: {
    next: function() {
      this.set('activity_index', Math.min(this.get('user_activities.length') - 1, this.get('activity_index') + 1));
      this.set('show_target_words', false);

      var user = app_state.get('currentUser');
      if(user && !user.get('preferences.progress.modeling_ideas_viewed')) {
        var progress = user.get('preferences.progress') || {};

        progress.modeling_ideas_viewed = true;
        user.set('preferences.progress', progress);
        user.save().then(null, function() { });
      } else if(this.get('current_activity.target_words')) {
        var progress = user.get('preferences.progress') || {};

        progress.modeling_ideas_target_words_reviewed = true;
        user.set('preferences.progress', progress);
        user.save().then(null, function() { });
      }
    },
    previous: function() {
      this.set('activity_index', Math.max(0, this.get('activity_index') - 1))
      this.set('show_target_words', false);
    },
    target_words: function() {
      this.set('show_target_words', !this.get('show_target_words'));
    },
    show_intro: function() {
      this.set('force_intro', true);
      this.set('activity_index', 0);
    },
    attempt: function() {
      // TODO: push something to the log
      this.set('current_activity.will_attempt', true);
    },
    dismiss: function() {
      // TODO: push something to the log
      this.set('current_activity.dismissed', true);
    },
    video: function() {
      var url = this.get('current_activity.url');

      var youtube_regex = (/(?:https?:\/\/)?(?:www\.)?youtu(?:be\.com\/watch\?(?:.*?&(?:amp;)?)?v=|\.be\/)([\w \-]+)(?:&(?:amp;)?[\w\?=]*)?/);
      var youtube_match = url && url.match(youtube_regex);
      var youtube_id = youtube_match && youtube_match[1];

      if(youtube_id) {
        modal.open('inline-video', {video: {type: 'youtube', id: youtube_id}});
      }
    },
    book: function() {
      var act = this.get('current_activity');
      modal.open('inline-book', {url: act.url});
    }
  }
});
