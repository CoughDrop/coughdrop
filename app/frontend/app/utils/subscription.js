import EmberObject from '@ember/object';
import { later as runLater } from '@ember/runloop';
import RSVP from 'rsvp';
import $ from 'jquery';
import i18n from './i18n';
import CoughDrop from '../app';
import persistence from './persistence';
import app_state from './app_state';
import stashes from './_stashes';
import capabilities from './capabilities';
import progress_tracker from './progress_tracker';
import { observer } from '@ember/object';
import { computed } from '@ember/object';

var types = ['communicator_type', 'supporter_type', 'monthly_subscription', 'long_term_subscription',
  'communicator_monthly_subscription', 'communicator_long_term_subscription',
  'monthly_6', 'monthly_9',
  'monthly_ios', 'long_term_ios',
  'long_term_145', 'long_term_295', 'long_term_custom',
  'eval_long_term',
  'slp_long_term',
  'subscription_amount'];
var obs_properties = [];
types.forEach(function(type) {
  obs_properties.push('subscription.' + type);
});
var one_time_id = 'CoughDropiOSBundle';
var long_term_id = 'CoughDropiOSPlusExtras';
var eval_id = 'CoughDropiOSEval';
var slp_id = 'CoughDropiOSSLP';
var subscription_id = 'CoughDropiOSMonthly';

var obs_func = function() {
  var _this = this;
  types.forEach(function(type) {
    var res = "btn ";
    if(type == 'long_term_custom') {
      if(_this.get('subscription.long_term_custom')) {
        res = res + "btn-primary active btn-lg";
      } else {
        res = res + "";
      }
    } else if(_this.get('subscription.' + type)) {
      res = res + "btn-primary active";
    } else {
      res = res + "btn-default";
    }
    _this.set(type + '_class', res);
  });
};

var Subscription = EmberObject.extend({
  init: function() {
    this.reset();
  },
  reset: function() {
    this.set('user_type', 'communicator');
    this.set('subscription_type', 'monthly');
    this.set('subscription_amount', null);
    this.set('show_options', false);
    this.set('show_cancel', false);
    this.set('extras', false);
    this.set('included_supporters', 0);
    this.set('finalizing_purchase', false);
    this.set('purchase_complete', false);
    this.set('canceling', false);
    this.set('gift_status', null);
    this.set('discount_percent', null);
    this.set('user_expires', false);
    this.set('user_expiring', false);

    var now = window.moment()._d;
    var sale = new Date(CoughDrop.sale * 1000);
    if(sale && now && sale > now && !Subscription.product_types) {
      this.set('sale', !!CoughDrop.sale);
      this.set('sale_ends', sale);
    }
    var _this = this;
    runLater(function() {
      var sale = new Date(CoughDrop.sale * 1000);
      if(sale && now && sale > now && !Subscription.product_types) {
        _this.set('sale', !!CoughDrop.sale);
        _this.set('sale_ends', sale);
      }
    }, 500);
    this.set('email', null);
    if(this.get('user')) {
      var u = this.get('user');
      var plan = u.get('subscription.plan_id');

      this.set('email', u.get('email'));
      this.set('name', u.get('name'));

      if(u.get('preferences.role') == 'supporter') {
        this.set('user_type', 'supporter');
      } else if(['therapist', 'other'].indexOf(u.get('preferences.registration_type')) >= 0) {
        this.set('user_type', 'supporter');
      }
      if(this.get('minimal_premium')) {
        // If premium already purchased, then 
        // there's nothing left to do but upgrade
        this.set('user_type', 'communicator');
      }

      if(u.get('subscription.expires')) {
        var expires = window.moment(u.get('subscription.expires'));
        var now = window.moment(new Date());
        var future = window.moment(new Date()).add(30, 'day');
        if(expires < now && !u.get('supporter_role')) {
          // expired
          this.set('user_expired', true);
          this.set('show_options', true);
        } else if(expires < future && !u.get('supporter_role')) {
          // expiring soon-ish
          this.set('user_expiring', true);
          this.set('show_options', true);
        } else {
          // not expiring for a while
          this.set('user_expiring', false);
        }
      }
      if(plan) {
        if(plan.match(/^monthly/) || plan.match(/^long/)) {
          this.set('user_type', 'communicator');
        } else if(plan.match(/^eval/)) {
          this.set('eval', true);
          this.set('user_type', 'communicator');
        } else {
          this.set('user_type', 'supporter');
        }
        this.set('subscription_plan', plan);
        this.set('subscription_amount', plan.replace(/_plus_trial$/, ''));
      }
    }
    if(this.get('code')) {
      this.set('show_options', true);
      this.set('subscription_type', 'gift_code');
      this.set('gift_code', this.get('code'));
      this.set('code', null);
      var _this = this;
      runLater(function() {
        _this.check_gift();
      })
    }
    if(Subscription.in_app_store) {
      this.refresh_store();
    }
    this.set_default_subscription_amount();
  },
  discount_period: computed('user.joined_within_24_hours', function() {
    return false;
//    return !!this.get('user.joined_within_24_hours');
  }),
  valid: computed(
    'user_type',
    'subscription_type',
    'gift_code',
    'user.lapsed',
    'email',
    'subscription_custom_amount',
    function() {
      if(this.get('subscription_type') == 'gift_code') {
        return !!this.get('gift_code');
      } else if(this.get('subscription_type') == 'long_term_gift') {
        if(this.get('subscription_amount') == 'long_term_custom') {
          var amount = parseInt(this.get('subscription_custom_amount'), 10);
          return this.get('any_subscription_amount') || (amount > 100 && (amount % 50 === 0));
        } else if(CoughDrop.sale && this.get('subscription_amount') == 'long_term_145') {
          return true;
        } else {
          return !!(this.get('email') && ['long_term_150', 'long_term_200', 'long_term_250', 'long_term_295'].indexOf(this.get('subscription_amount')) != -1);
        }
      } else if(this.get('subscription_type') == 'extras') {
        if(this.get('subscription_amount') == 'long_term_custom') {
          return this.get('subscription_custom_amount') == 25;
        }
        return false;
      } else if(this.get('user_type') == 'communicator') {
        if(this.get('eval')) {
          return ['eval_long_term_45', 'eval_long_term_ios'].indexOf(this.get('subscription_amount')) != -1;
        } else {
          if(this.get('subscription_type') == 'monthly') {
            return ['monthly_6', 'monthly_9', 'monthly_ios'].indexOf(this.get('subscription_amount')) != -1;
          } else {
            var valids = ['long_term_145', 'long_term_150', 'long_term_295', 'long_term_ios'];
            if(this.get('user.lapsed')) {
              valids.push('long_term_50');
            }
            return valids.indexOf(this.get('subscription_amount')) != -1;
          }  
        }
        } else {
        if(this.get('subscription_type') == 'monthly') {
          return this.get('subscription_amount') == 'slp_monthly_free';
        } else {
          return ['slp_long_term_free', 'slp_long_term_45', 'slp_long_term_50', 'slp_long_term_145', 'slp_long_term_150', 'slp_long_term_ios'].indexOf(this.get('subscription_amount')) != -1;
        }
      }
    }
  ),
  subscription_amount_plus_trial: computed('subscription_amount', 'discount_period', function() {
    if(this.get('discount_period') && ['long_term_145'].indexOf(this.get('subscription_amount')) != -1) {
      return this.get('subscription_amount') + '_plus_trial';
    } else if(this.get('sale') && ['long_term_145'].indexOf(this.get('subscription_amount')) != -1) {
      return this.get('subscription_amount') + '_plus_trial';
    }
    return this.get('subscription_amount');
  }),
  subscription_discount: computed('user.subscription.plan_id', function() {
    return !!(this.get('user.subscription.plan_id') || '').match(/monthly_3/);
  }),
  much_cheaper_offer: computed(
    'sale',
    'user.subscription.plan_id',
    'app_state.app_store_purchase_types',
    function() {
      if(Subscription.product_types) { return false; }
      return !!(this.get('sale') || (this.get('user.subscription.plan_id') || '').match(/monthly_3/));
    }
  ),
  cheaper_offer: computed(
    'sale',
    'discount_period',
    'user.subscription.plan_id',
    'app_state.app_store_purchase_types',
    function() {
      if(Subscription.product_types) { return false; }
      return !!(this.get('sale') || this.get('discount_period') || (this.get('user.subscription.plan_id') || '').match(/monthly_4/) || (this.get('user.subscription.plan_id') || '').match(/monthly_3/));
    }
  ),
  update_on_much_cheaper_offer: observer(
    'subscription_amount',
    'discount_percent',
    'user.lapsed',
    'much_cheaper_offer',
    function() {
      if(this.get('user.lapsed') && !this.get('discount_percent') && ['long_term_295', 'long_term_150'].indexOf(this.get('subscription_amount')) != -1) {
        this.set('subscription_amount', 'long_term_50');
      } else if(this.get('much_cheaper_offer') && !this.get('discount_percent') && ['long_term_295', 'long_term_150'].indexOf(this.get('subscription_amount')) != -1) {
        this.set('subscription_amount', 'long_term_145');
      }
    }
  ),
  no_purchasing: computed(
    'app_state.feature_flags.app_store_purchases',
    'app_state.installed_app',
    'app_state.app_store_purchase_types',
    function() {
      return app_state.get('installed_app') && (!Subscription.product_types || !app_state.get('feature_flags.app_store_purchases'));
    }
  ),
  app_pricing_override: computed('app_state.app_store_purchase_types', function() {
    return !!Subscription.product_types;
  }),
  app_pricing_override_no_monthly: computed(
    'app_state.app_store_purchase_types',
    'app_state.feature_flags.app_store_monthly_purchases',
    function() {
      return !!Subscription.product_types && !app_state.get('feature_flags.app_store_monthly_purchases');
    }
  ),
  manual_refresh: computed('app_pricing_override', function() {
    return this.get('app_pricing_override') && capabilities.system == 'iOS' && capabilities.installed_app;
  }),
  refresh_store: function(force) {
    if(Subscription.in_app_store) {
      if(force) { // || !Subscription.in_app_store.last_refresh) { // || Subscription.in_app_store.last_refresh < ((new Date()).getTime() - (5 * 60 * 1000))) {
        Subscription.in_app_store.last_refresh = (new Date()).getTime();
        console.log("app store refresh due to external call", force);
        Subscription.in_app_store.refresh();
      }
    }
  },
  has_app_subscription: computed('app_state.app_store_purchase_types', function() {
    if(Subscription.product_types && Subscription.product_types[subscription_id] && Subscription.product_types[subscription_id].valid && Subscription.product_types[subscription_id].owned) {
      return true;
    }
    return false;
  }),
  manage_subscriptions: function() {
    if(Subscription.in_app_store) {
      Subscription.in_app_store.manageSubscriptions();
    }
  },
  monthly_app_price: computed('app_state.app_store_purchase_types', function() {
    var prod = Subscription.product_types[subscription_id];
    if(!prod || !prod.price) { return "8.99"; }
    return prod.price;
  }),
  long_term_app_price: computed('app_state.app_store_purchase_types', function() {
    var prod = Subscription.product_types[long_term_id] || Subscription.product_types[one_time_id];
    if(!prod || !prod.price) { return "249.99" }
    return prod.price;
  }),
  supporter_app_price: computed('app_state.app_store_purchase_types', function() {
    var prod = Subscription.product_types[slp_id];
    if(!prod || !prod.price) { return "29.99" }
    return prod.price;
  }),
  eval_app_price: computed('app_state.app_store_purchase_types', function() {
    var prod = Subscription.product_types[eval_id];
    if(!prod || !prod.price) { return "29.99" }
    return prod.price;
  }),
  app_currency: computed('app_state.app_store_purchase_types', function() {
    var prod = Subscription.product_types[subscription_id] || Subscription.product_types[long_term_id] || Subscription.product_types[one_time_id];
    return prod.currency || "USD";
  }),
  set_default_subscription_amount: observer(
    'user_type',
    'subscription_type',
    'subscription_amount',
    'app_state.app_store_purchase_types',
    function(obj, changes) {
      window.subscr = this;
      if(this.get('user_type') == 'communicator') {
        if(this.get('subscription_amount') != 'reset' && (!this.get('subscription_amount') || !this.get('subscription_amount').match(/^(eval_|monthly_|long_term_)/))) {
          this.set('subscription_type', 'monthly');
        }
        if(this.get('subscription_type') == 'monthly') {
          this.set('eval', false);
          if(!this.get('subscription_amount') || !this.get('subscription_amount').match(/^monthly_/)) {
            if(Subscription.product_types) {
              // TODO: switch this for monthly_ios once it's an option
              this.set('subscription_amount', 'monthly_ios');
              // this.set('subscription_type', 'long_term');
              // this.set('subscription_amount', 'long_term_ios');
            } else {
              this.set('subscription_amount', 'monthly_9');
            }
          }
        } else if(this.get('subscription_type') == 'long_term') {
          if(this.get('subscription_amount') && this.get('subscription_amount').match(/^long_term_eval/)) {
            this.set('eval', true);
            if(Subscription.product_types) {
              this.set('subscription_amount', 'eval_long_term_ios');
            } else {
              this.set('subscription_amount', 'eval_long_term_45');
            }  
          } else if(!this.get('subscription_amount') || !this.get('subscription_amount').match(/^(eval_)?long_term_/)) {
            this.set('eval', false);
            if(Subscription.product_types) {
              this.set('subscription_amount', 'long_term_ios');
            } else if(this.get('much_cheaper_offer')) {
              this.set('subscription_amount', 'long_term_145');
            } else if(this.get('cheaper_offer')) {
              this.set('subscription_amount', 'long_term_150');
            } else {
              this.set('subscription_amount', 'long_term_295');
            }  
          }
        }
        if(this.get('subscription_amount') && this.get('subscription_amount').match(/^long_term/)) {
          this.set('included_supporters', this.get('included_supporters') || 0);
        } else {
          this.set('included_supporters', 0);
        }
      } else {
        this.set('eval', false);
        if(changes == 'user_type') {
          this.set('subscription_type', 'long_term');
        }
        if(this.get('subscription_amount') == 'slp_long_term_free' || this.get('subscription_amount') == 'slp_monthly_free') {
          this.set('subscription_amount', 'slp_monthly_free');
          this.set('subscription_type', 'monthly');
        } else if(!this.get('subscription_amount') || !this.get('subscription_amount').match(/^slp_long_term/)) {
          this.set('subscription_type', 'long_term');
          if(Subscription.product_types) {
            this.set('subscription_amount', 'slp_long_term_ios');
          } else {
            this.set('subscription_amount', 'slp_long_term_45');
          }
        }
        if(this.get('subscription_amount') && this.get('subscription_amount').match(/^slp_long_term/)) {
          this.set('subscription_type', 'long_term');
        }
      }
    }
  ),
  communicator_type: computed('user_type', function() {
    return this.get('user_type') == 'communicator';
  }),
  supporter_type: computed('user_type', function() {
    return this.get('user_type') == 'supporter';
  }),
  gift_type: computed('subscription_type', function() {
    return this.get('subscription_type') == 'gift_code';
  }),
  communicator_monthly_subscription: computed('user_type', 'subscription_type', function() {
    return this.get('user_type') == 'communicator' && this.get('subscription_type') == 'monthly';
  }),
  communicator_long_term_subscription: computed('eval', 'user_type', 'subscription_type', function() {
    return !this.get('eval') && this.get('user_type') == 'communicator' && this.get('subscription_type') == 'long_term';
  }),
  eval_long_term: computed('eval', 'user_type', 'subscription_type', function() {
    return this.get('eval') && this.get('user_type') == 'communicator' && this.get('subscription_type') == 'long_term';
  }),
  monthly_subscription: computed('subscription_type', function() {
    return this.get('subscription_type') == 'monthly';
  }),
  long_term_subscription: computed('subscription_type', function() {
    return this.get('subscription_type') == 'long_term';
  }),
  monthly_6: computed('subscription_amount', function() {
    return this.get('subscription_amount') == 'monthly_6';
  }),
  monthly_9: computed('subscription_amount', function() {
    return this.get('subscription_amount') == 'monthly_9';
  }),
  monthly_ios: computed('subscription_amount', function() {
    return this.get('subscriptionn_amount') == 'monthly_ios';
  }),
  slp_long_term: computed('subscription_amount', function() {
    return (this.get('subscription_amount') || '').match(/^slp_long_term/) && !(this.get('subscription_amount') || '').match(/free/);
  }),
  modeling_long_term: computed('subscription_amount', function() {
    return this.get('subscription_amount') == 'slp_monthly_free' || this.get('subscription_amount') == 'slp_long_term_free';
  }),
  long_term_ios: computed('subscription_amount', function() {
    return this.get('subscriptionn_amount') == 'long_term_ios';
  }),
  long_term_100: computed('subscription_amount', function() {
    return this.get('subscription_amount') == 'long_term_100';
  }),
  long_term_145: computed('subscription_amount', function() {
    return this.get('subscription_amount') == 'long_term_145';
  }),
  long_term_150: computed('subscription_amount', function() {
    return this.get('subscription_amount') == 'long_term_150';
  }),
  long_term_200: computed('subscription_amount', function() {
    return this.get('subscription_amount') == 'long_term_200';
  }),
  long_term_295: computed('subscription_amount', function() {
    return this.get('subscription_amount') == 'long_term_295';
  }),
  long_term_custom: computed('subscription_amount', function() {
    return this.get('subscription_amount') == 'long_term_custom';
  }),
  slp_long_term_45: computed('subscription_amount', function() {
    return this.get('subscription_amount') == 'slp_long_term_45';
  }),
  long_term_amount: computed('user.lapsed', 'much_cheaper_offer', 'cheaper_offer', 'discount_percent', function() {
    var num = 295;
    if(this.get('user.lapsed')) {
      num = 50;
    } else if(this.get('much_cheaper_offer')) {
      num = 145;
    } else if(this.get('cheaper_offer')) {
      num = 150;
    }
    if(this.get('discount_percent')) {
      num = Math.max(0, num * (1 - this.get('discount_percent')));
    }
    return num;
  }),
  extras_in_dollars: computed(
    'extras',
    'communicator_type',
    'long_term_subscription',
    'included_supporters',
    function() {
      if(this.get('long_term_subcription') || !this.get('communicator_type')) { return 0; }
      var amt = 0;
      if(this.get('extras')) { amt = amt + 45; }
      if(this.get('included_supporters') > 0) { amt = amt + (45 * this.get('included_supporters')); }
      return amt;
    }
  ),
  amount_in_cents: computed(
    'subscription_amount',
    'valid',
    'extras',
    'included_supporters',
    'donate',
    'communicator_type',
    'long_term_subscription',
    'discount_percent',
    'subscription_type',
    function() {
      if(this.get('valid')) {
        var num = this.get('subscription_amount').split(/_/).pop();
        if(num == 'free') {
          return 0;
        } else {
          if(this.get('subscription_amount') == 'long_term_custom') {
            num = parseInt(this.get('subscription_custom_amount'), 10);
          } else if(this.get('subscription_amount') == 'monthly_ios') {
            num = this.get('monthly_app_price');
          } else if(this.get('subscription_amount') == 'long_term_ios') {
            num = this.get('long_term_app_price');
          } else if(this.get('subscription_amount') == 'slp_long_term_ios') {
            num = this.get('supporter_app_price');
          } else if(this.get('subscription_amount') == 'eval_long_term_ios') {
            num = this.get('eval_app_price');
          }
          var num = parseInt(num, 10) * 100;
          if(!this.get('app_pricing_override')) {
            if(this.get('discount_percent') && this.get('communicator_type') && !this.get('eval') && this.get('long_term_subscription')) {
              num = Math.max(0, num * (1 - this.get('discount_percent')));
            }
            if(this.get('extras') && !this.get('free_extras') && this.get('long_term_subscription')) {
              num = num + (45 * 100);
            }
            if(this.get('communicator_type') && this.get('included_supporters') && !this.get('free_supporters') && this.get('long_term_subscription')) {
              num = num + (45 * 100 * this.get('included_supporters'));
            }
          }
          if(this.get('subscription_type') == 'long_term_gift') {
            if(this.get('extras') && !this.get('free_extras')) {
              num = num + (45 * 100);
            }
            if(this.get('communicator_type') && this.get('included_supporters') && !this.get('free_supporters')) {
              num = num + (45 * 100 * this.get('included_supporters'));
            }
            if(this.get('donate')) {
              num = num + (50 * 100);
            }
          }
          return num;
        }
      } else {
        return null;
      }
    }
  ),
  amount_in_dollars: computed('amount_in_cents', function() {
    return (this.get('amount_in_cents') || 0) / 100;
  }),
  partial_gift_allowed: computed('app_state.app_store_purchase_types', function() {
    return !Subscription.product_types;
  }),
  check_gift: function() {
    var _this = this;
    var code = _this.get('gift_code');
    _this.set('gift_status', {checking: true});
    persistence.ajax('/api/v1/gifts/code_check?code=' + code, {
      type: 'GET'
    }).then(function(res) {
      var num = 1.0;
      if(res.valid && (res.discount_percent >= 1.0 || _this.get('partial_gift_allowed'))) {
        _this.set('discount_percent', res.discount_percent);
        _this.set('subscription_type', 'long_term');
        _this.set('user_type', 'communicator');
        _this.set('eval', false);
        if(res.extras) {
          _this.set('extras', true);
          _this.set('free_extras', true);
        } else {
          _this.set('free_extras', false);
        }
        if(res.supporters) {
          _this.set('included_supporters', res.supporters);
          // TODO: free supporters means dropdown should be disabled
          _this.set('free_supporters', true);
        } else {
          _this.set('free_supporters', false);
        }
        _this.set('subscription_amount', 'long_term_295');
        _this.set('gift_status', null);
      } else {
        _this.set('gift_status', {error: true});
      }
    }, function(err) {
      _this.set('gift_status', {error: true});
    })
  },
  description: computed('user_type', 'subscription_type', 'extras', 'included_supporters', 'communicator_type', function() {
    var res = i18n.t('coughdrop_license', "%app_name% license");
    if(this.get('user_type') == 'communicator') {
      if(this.get('eval')) {
        res = i18n.t('eval_sub', "%app_name% evaluation account");
      } else if(this.get('subscription_type') == 'extras') {
        res = i18n.t('extras_purchase', "%app_name% premium symbols")
      } else {
        if(this.get('subscription_type') == 'monthly') {
          res = i18n.t('monthly_sub', "%app_name% monthly subscription");
        } else {
          res = i18n.t('long_term_sub', "%app_name% lifetime purchase");
        }
      }
    } else {
      res = i18n.t('slp_long_term_sub', "%app_name% supporting-role long-term purchase");
    }
    if(this.get('extras')) {
      res = res + " " + i18n.t('plus_extras', "Plus Premium Symbols");
    }
    if(this.get('communicator_type') && this.get('included_supporters')) {
      res = res + " " + i18n.t('plus_supporters', "Plus %{n} Premium Supporters", {n: this.get('included_supporters')});
    }
    return res;
  }),
  minimal_premium: computed(
    'user.subscription.never_expires',
    'user.subscription.premium_supporter',
    'user.subscription.grace_period',
    function() {
      return !this.get('user.subscription.grace_period') && (this.get('user.subscription.never_expires') || this.get('user.subscription.premium_supporter'));
    }
  ),
  subscription_plan_description: computed(
    'subscription_plan',
    'user.subscription.never_expires',
    'user.subscription.org_sponsored',
    function() {
      var plan = this.get('subscription_plan');
      if(!plan) {
        if(this.get('user.subscription.never_expires')) {
          return "free forever";
        } else if(this.get('user.is_sponsored')) {
          return "sponsored by " + this.get('user.managing_org.name');
        } else if(this.get('user.subscription.eval_account')) {
          return "eval";
        } else if(this.get('user.subscription.premium_supporter_plus_communicator')) {
          return "paid communicator-turned-supporter";
        } else if(this.get('user.subscription.premium_supporter')) {
          return "premium supporter";
        } else {
          return "no plan";
        }
      }
      var pieces = plan.replace(/_plus_trial/, '').split(/_/);
      var amount = pieces.pop();
      if(amount != 'free') { amount = '$' + amount; }
      var type = "communicator ";
      if(plan.match(/^slp_/)) {
        type = "supporter ";
      } else if(plan.match(/^eval_/)) {
        type = "eval device ";
      }
      var schedule = "monthly ";
      if(plan.match(/long_term/)) {
        schedule = "long-term ";
      }
      return type + schedule + amount;
    }
  ),
  purchase_description: computed('subscription_type', 'extras', function() {
    var res = i18n.t('activate', "Activate");
    if(this.get('subscription_type') == 'monthly') {
      if(this.get('subscription_amount') && this.get('subscription_amount').match(/free/)) {
        res = i18n.t('purchase', "Purchase");
      } else {
        res = i18n.t('subscribe', "Subscribe");
      }
    } else {
      res = i18n.t('purchase', "Purchase");
    }
    return res;
  })
});

Subscription.reopenClass({
  obs_func: obs_func,
  obs_properties: obs_properties,
  init: function() {
    if(window.StripeCheckout) { return; }
    var $div = $("<div/>", {id: 'stripe_script'});
    var script = document.createElement('script');
    script.src = 'https://checkout.stripe.com/checkout.js';
    $div.append(script);
    var config = document.createElement('script');
    document.body.appendChild($div[0]);

    var check_for_ready = function() {
      if(window.StripeCheckout && window.stripe_public_key) {
        Subscription.handler = window.StripeCheckout.configure({
          key: window.stripe_public_key,
          image: '/images/logo-big.png',
          opened: function() {
          },
          closed: function() {
            var d = Subscription.handler.defer;
            runLater(function() {
              if(d && Subscription.handler.defer == d) {
                if(Subscription.handler.defer) {
                  Subscription.handler.defer.reject();
                  Subscription.handler.defer = null;
                }
              }
            }, 1000);
          },
          token: function(result) {
            Subscription.handler.defer.resolve(result);
            Subscription.handler.defer = null;
          }
        });
        Subscription.ready = true;
      } else if(window.stripe_public_key) {
        setTimeout(check_for_ready, 500);
      }
    };

    check_for_ready();
  },
  purchase: function(subscription) {
    if(Subscription.in_app_store) {
      var defer = RSVP.defer();
      var purchase_id = one_time_id;
      if(Subscription.product_types && Subscription.product_types[long_term_id]) {
        purchase_id = long_term_id;
      }
      var amt = subscription.get('subscription_amount');

      if(subscription.get('subscription_type') == 'monthly') {
        purchase_id = subscription_id;
      } else if(Subscription.product_types && Subscription.product_types[eval_id] && amt && amt.match(/^eval/)) {
        purchase_id = eval_id;
      } else if(Subscription.product_types && Subscription.product_types[eval_id] && amt && amt.match(/^slp/)) {
        purchase_id = slp_id;
      }
      Subscription.in_app_store.defer = defer;
      Subscription.in_app_store.user_id = subscription.get('user.id');
      Subscription.in_app_store.user = subscription.get('user');
      // TODO: long-term purchase is a one-time offering right now,
      // meaning you can't re-buy it. We
      // will need a subscription/credit purchase fallback to
      // offer 5 years in the future.
      if(Subscription.product_types && Subscription.product_types[purchase_id] && Subscription.product_types[purchase_id].valid && Subscription.product_types[purchase_id].owned) {
        // If already owned, we won't have a receipt to verify
        // but re-purchase won't really be possible. This manual
        // call to validator will fail without a receipt (product.transaction).
        Subscription.in_app_store.validator(Subscription.product_types[purchase_id], function(success, data) {
          if(success) {
            defer.resolve({id: 'ios_iap'});
          } else {
            defer.reject(data);
          }
        });        
      } else {
        Subscription.in_app_store.order(purchase_id);
      }
      return defer.promise;
    } else {
      if(!window.StripeCheckout || !Subscription.handler) {
        alert('not ready');
        return RSVP.reject({error: "not ready"});
      }
      var amount = subscription.get('amount_in_cents');
      if(subscription.get('subscription_amount') && subscription.get('subscription_amount').match(/free/)) {
        if (subscription.get('extras')) {
          amount = (45 * 100);
        } else {
          return RSVP.resolve({id: 'free'});
        }
      }
      var defer = RSVP.defer();
      if(Subscription.handler.defer) {
      }
      Subscription.handler.open({
        name: subscription.get('name') || subscription.get('user.name') || CoughDrop.app_name,
        description: subscription.get('description'),
        amount: amount,
        panelLabel: subscription.get('purchase_description'),
        email: subscription.get('email') || subscription.get('user.email'),
        zipCode: true
      });
      Subscription.handler.defer = defer;
      return defer.promise;
    }
  }
});
document.addEventListener("deviceready", function() {
  if(window.store) {
    Subscription.in_app_store = window.store;
    Subscription.ready = true;
    var store = Subscription.in_app_store;
    store.disableHostedContent = true;
    store.register({
      id: one_time_id,
      alias: 'Long-Term Purchase',
      type: store.NON_CONSUMABLE
    });
    store.register({
      id: eval_id,
      alias: 'Eval Account Purchase',
      type: store.NON_CONSUMABLE
    });
    store.register({
      id: slp_id,
      alias: 'Premium Supporter Purchase',
      type: store.NON_CONSUMABLE
    });
    store.register({
      id: subscription_id,
      alias: 'Monthly Subscription',
      type: store.PAID_SUBSCRIPTION
    });
    store.validator = function(product, callback) {
      if(product.type == 'application') {
        return callback(true, {});
      }
      var user_id = store.user_id || Subscription.in_app_store.user_id || app_state.get('currentUser.id');
      var user = store.user || Subscription.in_app_store.user || app_state.get('currentUser');
      var pre_purchase = product.alias == 'App Pre-Purchase';
      var device_id = (window.device && window.device.uuid) || stashes.get_raw('coughDropDeviceId');
      if(!user_id) {
        return callback(false, {
          code: store.INTERNAL_ERROR,
          error: "User not initialized"
        });
      }
      var promise = null;
      if(user && (user.get('subscription.iap_purchases') || []).indexOf(product.id) != -1) {
        // If it's a long-term purchase and it's already
        // recorded on the user, we don't need to validate
        // the receipt with an API call every time we load
        // the app.
        promise = RSVP.resolve({
          success: true,
          event: {result: {}}
        });
        store.validator.promise = promise;
      }
      if(store.validator.promise) {
        promise = store.validator.promise;
      } else {
        promise = persistence.ajax('/api/v1/users/' + user_id + '/verify_receipt', {
          type: 'POST',
          data: {receipt_data: {ios: true, product_id: product.id, receipt: product.transaction, pre_purchase: pre_purchase, device_id: device_id}}
        }).then(function(res) {
          var defer = RSVP.defer();
          progress_tracker.track(res.progress, function(event) {
            if(event.status == 'errored') {
              defer.resolve({
                error: true,
                event: event
              })
            } else if (event.result && (event.result.success === false || event.result.error === true)) {
              defer.resolve({
                error2: true,
                event: event
              })
            } else if(event.status == 'finished') {
              defer.resolve({
                success: true,
                event: event
              })
            }
          });
          return defer.promise;
        });
        store.validator.promise = promise;
      }
      promise.then(function(res) {
        var event = res.event;
        store.validator.promise = null;
        if(res.error) {
          callback(false, {
            code: store.INTERNAL_ERROR,
            error: (event.result || {}).error_message || "Receipt validation failed"
          });
        } else if(res.success) {
          var res = event.result;
          if(res.expired) {
            store.validator.promise = null;
            callback(false, {
              code: store.PURCHASE_EXPIRED,
              error: { message: "expired" }
            });
          } else {
            store.validator.promise = null;
            callback(true, res);
          }
        } else {
          callback(false, {
            code: store.INTERNAL_ERROR,
            wrong_user: (event.result || {}).wrong_user,
            error: (event.result || {}).error_message || "Receipt validation did not succeed"
          });
        }
      }, function(err) {
        store.validator.promise = null;
        callback(false, {
          code: store.INTERNAL_ERROR,
          error: (err || {}).message || "Receipt validation failed to initiate"
        });
      });
    };
    store.error(function(err) {
      if(store.defer) {
        store.defer.reject(err);
        store.defer = null;
      }
    });
    store.when("product").loaded(function(product) {
      if(product.valid) {
        Subscription.product_types = Subscription.product_types || {};
        Subscription.product_types[product.id] = product;
        app_state.set('app_store_purchase_types', Subscription.product_types);
      }
    });
    store.when("subscription").updated(function(product) {
      if(!product.owned) {
        if(!product.transaction) {
          var now = (new Date()).getTime();
          if(!Subscription.in_app_store.checked_for_transaction || (now - Subscription.in_app_store.checked_for_transaction) > (5 * 60 * 1000)) {
            if(now - Subscription.in_app_store.last_refresh > (30 * 1000)) {
              Subscription.in_app_store.last_refresh = (new Date()).getTime();
              console.log("app store refresh due to subscription update");
               Subscription.in_app_store.refresh();
            }
          }
          Subscription.in_app_store.checked_for_transaction = now;
        } else {
          Subscription.in_app_store.validator(Subscription.product_types[subscription_id], function(success, data) {
            if(!success && data.code == store.PURCHASE_EXPIRED) {
              app_state.get('sessionUser').reload(true);
            }
          });        
        }
      }
    });
    store.when("product").approved(function(product) {
      var promise = product.verify();
      promise.success(function(product, purchaseData) {

      });
      promise.error(function(err) {
        console.error("verification error", err);
      })
    });
    store.when("product").cancelled(function(product) {
      if(store.defer) {
        store.defer.reject({error: 'cancelled'});
        store.defer = null;
      }
    });
    store.when("product").verified(function(product) {
      product.finish();
    });
    store.when("product").finished(function(product) {
      if(app_state.get('sessionUser')) {
        app_state.get('sessionUser').reload();
        if(store.defer) {
          store.defer.resolve({id: 'ios_iap'});
          store.defer = null;
        }  
      } else {
        // TODO: wait until user is available?
      }
    });
    capabilities.bundle_id().then(function(res) {
      // Don't register known-free bundles`
      if(res.bundle_id != "com.mycoughdrop.coughdrop") {
        var app_bundle_id = res.bundle_id;
        store.register({
          id: app_bundle_id,
          alias: 'App Pre-Purchase',
          type: store.NON_CONSUMABLE
        });  
      }
      if(!store.last_refresh) {
        store.last_refresh = (new Date()).getTime();
        console.log("app store refresh due to init");
        store.refresh();
      }
    }, function(err) {
      console.error("bundle id not found", err);
      if(!store.last_refresh) {
        store.last_refresh = (new Date()).getTime();
        console.log("app store refresh due to init");
        store.refresh();
      }
    });
    document.addEventListener("resume", function() {
      if(Subscription.in_app_store && Subscription.in_app_store.defer) {
        store.last_refresh = (new Date()).getTime();
        console.log("app store refresh due to returning to app");
        store.refresh();
      }
    }, false);
  }
}, false);

CoughDrop.Subscription = Subscription;

export default Subscription;
