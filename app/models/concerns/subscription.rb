module Subscription
  extend ActiveSupport::Concern
  
  def clear_existing_subscription(opts={})
    opts = opts || {}
    self.settings['subscription'] ||= {}
    if opts[:track_seconds_left]
      if self.expires_at && self.expires_at > Time.now
        self.settings['subscription']['seconds_left'] = [(self.settings['subscription']['seconds_left'] || 0), (self.expires_at.to_i - Time.now.to_i)].max
        self.settings['subscription']['seconds_left_source'] = self.settings['subscription']['expiration_source']
      end
      self.expires_at = nil
    else
      if self.settings['subscription']['seconds_left']
        self.expires_at = [self.expires_at, Time.now + self.settings['subscription']['seconds_left']].compact.max
        self.settings['subscription'].delete('seconds_left')
        self.settings['subscription']['expiration_source'] = self.settings['subscription']['seconds_left_source'] if self.settings['subscription']['seconds_left_source']
        self.settings['subscription']['expiration_source'] = 'grace_period' if self.settings['subscription']['expiration_source'] == 'free_trial'
        self.settings['subscription'].delete('seconds_left_source')
      end
    end
    
    if self.billing_state('communicator') == :subscribed_communicator
      started = Time.parse(self.settings['subscription']['started']) rescue nil
      if started
        self.settings['past_purchase_durations'] ||= []
        self.settings['past_purchase_durations'] << {role: 'communicator', type: 'recurring', started: self.settings['subscription']['started'], duration: (Time.now.to_i - started.to_i)}
      end
      if self.settings['subscription']['subscription_id'] && self.settings['subscription']['customer_id']
        # If there is an existing subscription, schedule the API call to cancel it
        Worker.schedule(Purchasing, :cancel_subscription, self.global_id, self.settings['subscription']['customer_id'], self.settings['subscription']['subscription_id'])
      end
      self.settings['subscription']['limited_premium_purchase'] ||= self.settings['subscription']['free_premium'] if self.settings['subscription']['free_premium']
      ['subscription_id', 'token_summary', 'started', 'plan_id', 'limited_premium_purchase', 'eval_account', 'modeling_only', 'never_expires'].each do |key|
        self.settings['subscription']['canceled'] ||= {}
        self.settings['subscription']['canceled'][key] = self.settings['subscription'][key]
      end
    end
    ['subscription_id', 'token_summary', 'started', 'plan_id', 'free_premium', 'limited_premium_purchase', 'eval_account', 'modeling_only'].each do |key|
      self.settings['subscription'].delete(key)
    end
    
    self.settings['subscription'].delete('started')
    # self.settings['subscription'].delete('never_expires')
    self.settings['subscription'].delete('added_to_organization')
    if opts[:removed_org_links]
      self.settings['past_purchase_durations'] ||= []
      (opts[:removed_org_links] || []).each do |link|
        added = (link['state']['added'] && Time.parse(link['state']['added'])) rescue nil
        if added
          self.settings['past_purchase_durations'] << {role: 'communicator', type: 'org', started: link['state']['added'], duration: (Time.now.to_i - added.to_i)}
        end
      end
    end
    self.settings['managed_by'] = nil
    
    extra_expiration = (opts[:allow_grace_period] && !self.supporter_role?) ? 2.weeks.from_now : nil
    
    if self.settings['subscription']['org_sponsored']
      self.settings['subscription']['org_sponsored'] = nil
    end

    self.expires_at = [self.expires_at, extra_expiration].compact.max
    if opts[:allow_grace_period] && extra_expiration && self.expires_at == extra_expiration
      self.settings['subscription']['expiration_source'] = 'grace_period'
    end

    if self.settings['subscription']['last_purchase_plan_id'] && !self.settings['subscription']['last_purchase_plan_id'].match(/free/)
      purchased = Time.parse(self.settings['subscription']['last_purchased']) rescue nil
      if purchased
        self.settings['past_purchase_durations'] ||= []
        dur = {role: 'communicator', type: 'long_term', started: self.settings['subscription']['last_purchased'], duration: (Time.now.to_i - purchased.to_i)}
        if self.settings['subscription']['last_purchase_plan_id'].match(/^(slp|eval)/)
          dur[:role] = 'supporter'
        end
        self.settings['past_purchase_durations'] << dur
      end
      self.settings['subscription']['prior_purchase_ids'] << self.settings['subscription']['last_purchase_id']
      self.settings['subscription'].delete('last_purchase_id')
    end
    true
  end
  
  def update_subscription_organization(org_id, pending=false, sponsored=true, eval_account=false)
    # used to pause subscription when the user is adopted by an organization, 
    # and possibly to resume the subscription when the user is dropped by an organization.
    prior_org = self.managing_organization
    link = nil
    if org_id && (!org_id.is_a?(String) || !org_id.match(/^r/))
      new_org = org_id.is_a?(Organization) ? org_id : Organization.find_by_global_id(org_id)
      if new_org && self.settings['authored_organization_id'] == new_org.global_id && self.created_at > 2.weeks.ago
        pending = false
      end
      self.settings['subscription'] ||= {}
      if new_org
#        Organization.detach_user(self, 'user', new_org)
      end
      if sponsored
        self.clear_existing_subscription(:track_seconds_left => true)
      elsif org_sponsored? && sponsored == false
        # If we are being re-added to the sponsored org as
        # unsponsored, then we need to remove the sponsorship
        links = UserLink.links_for(self)
        sponsor = links.detect{|l| l['type'] == 'org_user' && l['user_id'] == self.global_id && l['state']['sponsored'] }
        sponsor_id = sponsor && sponsor['record_code'].split(/:/)[1]
        if sponsor_id == new_org.global_id
          RemoteAction.create(path: "#{self.global_id}::#{prior_org && prior_org.global_id}", act_at: 12.hours.from_now, action: 'notify_unassigned')
          self.clear_existing_subscription(:allow_grace_period => true)
        end
      end
      self.settings['subscription']['added_to_organization'] = Time.now.iso8601
      self.settings['subscription']['added_org_id'] = new_org.global_id if new_org
      self.settings['subscription']['eval_account'] = true if eval_account
      self.settings['preferences'] ||= {}
      self.settings['preferences']['role'] = 'communicator'

      if new_org
        link = UserLink.generate(self, new_org, 'org_user')
        if link.id && !link.data['state']['pending']
          pending = false
        end
        link.data['state']['added'] ||= Time.now.iso8601
        link.data['state']['pending'] = !!pending unless pending == nil
        link.data['state']['sponsored'] = !!sponsored unless sponsored == nil
        link.data['state']['eval'] = !!eval_account unless eval_account == nil
        @link_to_save = link
        self.log_subscription_event(:log => 'org added user', :args => {org_id: new_org.global_id, pending: pending, sponsored: sponsored, eval_account: eval_account, link_id: link.id})
        new_org.schedule(:org_assertions, self.global_id, 'user')

        if !pending
          if !self.settings['eval_reset']
            self.settings['eval_reset'] = {
              'email' => self.settings['email'],
              'home_board' => nil,
              'password' => self.settings['password'],
              'duration' => nil
            }
          end
        end

        if sponsored && !pending
          self.expires_at = nil
          self.schedule(:process_subscription_token, 'token', 'unsubscribe')
        end
      end

      self.settings['pending'] = false

      if !prior_org || prior_org != new_org
        UserMailer.schedule_delivery(:organization_assigned, self.global_id, new_org && new_org.global_id)
      end
      self.assert_current_record!
      link.save if link
      @link_to_save = nil
      res = self.save_with_sync('org_sub')
      return res
    else
      was_sponsored = self.org_sponsored?
      removed_links = []
      if org_id
        org_to_remove = Organization.find_by_global_id(org_id.sub(/^r/, ''))
        if org_to_remove
          org_code = Webhook.get_record_code(org_to_remove)
          removed_links = UserLink.links_for(self).select{|l| l['record_code'] == org_code && l['type'] == 'org_user' && l['state']['sponsored'] && l['state']['added'] }
          org_to_remove.detach_user(self, 'user')
          self.log_subscription_event(:log => 'org removed user', :args => {was_sponsored: was_sponsored})
          RemoteAction.create(path: "#{self.global_id}::#{prior_org && prior_org.global_id}", act_at: 12.hours.from_now, action: 'notify_unassigned')
        end
      end
      self.using(:master).reload
      self.settings['subscription'] ||= {}
      self.settings['subscription']['org_detach'] = org_id
      self.clear_existing_subscription(:allow_grace_period => true, removed_org_links: removed_links) if was_sponsored && !self.org_sponsored?
      self.save_with_sync('org_sub_cancel')
      # self.schedule(:update_subscription, {'resume' => true})
    end
    self.schedule_audit_protected_sources
  rescue ActiveRecord::StaleObjectError
    puts "stale :-/"
    if @link_to_save
      # Ensure user gets linked to org, even if other settings have to be re-processed
      @link_to_save.save
      @link_to_save = nil
    end
    self.log_subscription_event(:log => 'org stale update', :args => {org_id: org_id, pending: pending, sponsored: sponsored, eval_account: eval_account})
    self.schedule(:update_subscription_organization, org_id, pending, sponsored, eval_account)
  end
  
  def transfer_subscription_to(user, skip_remote_update=false)
    transfer_keys = ['started', 'plan_id', 'subscription_id', 'token_summary', 'limited_premium_purchase', 'eval_account', 'modeling_only',
      'never_expires', 'seconds_left', 'customer_id', 'last_purchase_plan_id', 'extras', 'expiration_source', 'seconds_left_source', 'purchased_supporters', 'allotted_supporter_ids']
    did_change = false
    self.settings['subscription'] ||= {}
    self.settings['subscription']['limited_premium_purchase'] ||= self.settings['subscription']['free_premium'] if self.settings['subscription']['free_premium']
    transfer_keys.each do |key|
      user.settings['subscription'] ||= {}
      if self.settings['subscription'][key] != nil || user.settings['subscription'][key] != nil
        did_change = true if ['subscription_id', 'customer_id'].include?(key)
        user.settings['subscription'][key] = self.settings['subscription'][key]
        self.settings['subscription'].delete(key)
      end
    end
    user.expires_at = self.expires_at
    user.settings['activated_sources'] = ((user.settings['activated_sources'] || []) + (self.settings['activated_sources'] || [])).uniq
    self.settings['activated_sources'] = []
    self.expires_at = Date.today + 60
    self.settings['subscription']['expiration_source'] = 'grace_period'
    if did_change && !skip_remote_update
      Purchasing.change_user_id(user.settings['subscription']['customer_id'], self.global_id, user.global_id)
    end
    from_list = (user.settings['subscription']['transferred_from'] || []) + [self.global_id]
    user.update_setting({
      'expires_at' => user.expires_at,
      'activated_sources' => user.settings['activated_sources'],
      'subscription' => {'transferred_from' => from_list}
    })
    to_list = (self.settings['subscription']['transferred_to'] || []) + [user.global_id]
    self.update_setting({
      'expires_at' => self.expires_at,
      'activated_sources' => self.settings['activated_sources'],
      'subscription' => {'transferred_to' => to_list, 'transfer_ts' => Time.now.to_i}
    })
  end
  
  def update_subscription(args)
    res = true
    self.settings['subscription'] ||= {}
    if args['subscribe']
      if !args['subscription_id'] || self.settings['subscription']['subscription_id'] == args['subscription_id']
        res = false
      else
        role = (args['plan_id'] && args['plan_id'].match(/^slp/)) ? 'supporter' : 'communicator'
        self.settings['subscription']['prior_subscription_ids'] ||= []
        if self.settings['subscription']['prior_subscription_ids'].include?(args['subscription_id'])
          res = false
        else
          self.clear_existing_subscription(:track_seconds_left => true)
          self.settings['subscription']['subscription_id'] = args['subscription_id']
          PurchaseToken.map("subscribe.#{args['source_id']}.#{args['subscription_id']}", args['device_id'], self)
          if self.settings['subscription']['subscription_id'] && !self.settings['subscription']['subscription_id'].match(/free/)
            self.settings['subscription']['prior_subscription_ids'] << self.settings['subscription']['subscription_id']
          end
          if args['customer_id']
            if self.settings['subscription']['customer_id'] && self.settings['subscription']['customer_id'] != args['customer_id']
              self.settings['subscription']['prior_customer_ids'] ||= []
              self.settings['subscription']['prior_customer_ids'] << self.settings['subscription']['customer_id']
            end
            self.settings['subscription']['customer_id'] = args['customer_id']
          end
          self.settings['purchase_bounced'] = false
          self.settings['subscription']['started'] = Time.now.iso8601 
          self.settings['subscription']['started'] = nil if args['plan_id'].match(/free|granted/)
          self.settings['subscription']['token_summary'] = args['token_summary']
          self.settings['subscription']['plan_id'] = args['plan_id']
          self.settings['subscription']['prior_purchase_plan_id'] = self.settings['subscription']['last_purchase_plan_id'] if self.settings['subscription']['last_purchase_plan_id']
          self.settings['subscription'].delete('last_purchase_plan_id')
          self.settings['subscription']['unsubscribe_reason'] = nil
          self.settings['subscription']['purchase_amount'] = args['purchase_amount']
          self.settings['subscription']['eval_account'] = !!args['plan_id'].match(/^eval/)
          self.settings['subscription']['limited_premium_purchase'] = !!(args['plan_id'].match(/^slp/) && !args['plan_id'].match(/free/))
          self.settings['subscription']['modeling_only'] = ['slp_long_term_free', 'slp_monthly_free'].include?(args['plan_id'])
          self.settings['subscription']['expiration_source'] = 'subscribe' if self.settings['subscription']['started']
          self.settings['preferences']['role'] = role
          self.settings['pending'] = false unless self.settings['subscription']['modeling_only']
          self.settings['preferences']['progress'] ||= {}
          self.settings['preferences']['progress']['subscription_set'] = true
          if self.full_premium?
            if ((self.settings['premium_voices'] || {})['trial_voices'] || []).length > 0
              # When a user fully subscribes, activate any trialed premium voices
              self.settings['premium_voices']['trial_voices'].each do |v| 
                self.track_voice_added(v['i'], v['s']) 
                self.settings['premium_voices']['allowed'] = [self.settings['premium_voices']['allowed'] || 0, self.default_premium_voices['allowed']].max
              end
              self.settings['premium_voices'].delete('trial_voices')
            end
          elsif self.modeling_only? && self.settings['premium_voices']
            self.settings['premium_voices']['allowed'] = self.settings['premium_voices']['extra'] || 0
            self.settings['premium_voices']['claimed'] = (self.settings['premium_voices']['claimed'] || [])[0, self.settings['premium_voices']['allowed']]
            self.settings['premium_voices'].delete('trial_voices')
          end
          self.expires_at = nil if self.settings['subscription']['started'] || args['plan_id'].match(/free|granted/)
          self.assert_current_record!
          self.save_with_sync('subscribe')

            
          self.schedule(:remove_supervisors!) if self.premium_supporter? || self.modeling_only?
        end
      end
    elsif args['unsubscribe']
      if (args['subscription_id'] && self.settings['subscription']['subscription_id'] == args['subscription_id']) || args['subscription_id'] == 'all'
        self.clear_existing_subscription(:allow_grace_period => true)
        if args['reason']
          reasons = [self.settings['subscription']['unsubscribe_reason'], args['reason']].compact.join(', ')
          self.settings['subscription']['unsubscribe_reason'] = reasons
        end
        self.settings['pending'] = false
        self.assert_current_record!
        self.save_with_sync('unsubscribe')
        if self.settings['subscription']['unsubscribe_reason'] && !self.long_term_purchase?
          SubscriptionMailer.schedule_delivery(:unsubscribe_reason, self.global_id)
        end
      else
        res = false
      end
    elsif args['purchase']
      if args['purchase_id'] && self.settings['subscription']['last_purchase_id'] == args['purchase_id']
        res = false
      elsif args['plan_id'] && args['plan_id'].match(/^refresh_long_term/) && !self.fully_purchased?
        res = false
      else
        self.settings['subscription']['prior_purchase_ids'] ||= []
        if args['purchase_id'] == 'restore' && self.settings['subscription']['last_paid_purchase_id'] && self.settings['subscription']['seconds_left']
          args['purchase_id'] = self.settings['subscription']['last_paid_purchase_id']
          args['plan_id'] = self.settings['subscription']['last_paid_purchase_plan_id']
          args['seconds_to_add'] = self.settings['subscription']['seconds_left']
          args['purchase_amount'] = self.settings['subscription']['last_paid_purchase_amount']
          args['source_id'] = 'restore'
          self.settings['subscription']['prior_purchase_ids'] -= [args['purchase_id']]
        end
        if args['purchase_id'] && self.settings['subscription']['prior_purchase_ids'].include?(args['purchase_id'])
          res = false
        else
          if args['plan_id'] && args['plan_id'].match(/^long_term/) && self.settings['subscription']['last_purchase_plan_id'] && self.settings['subscription']['last_purchase_plan_id'].match(/^slp/)
            # If the last purchase was for a supporter 
            # and now you're buying for a communicator,
            # don't count both for expires_at
            self.expires_at = nil
          end
          self.clear_existing_subscription(:track_seconds_left => (args['plan_id'] || '').match(/free|granted/) || args['source_id'] == 'restore')
          if args['customer_id'] || args['customer_id'] == nil
            if self.settings['subscription']['customer_id'] && self.settings['subscription']['customer_id'] != args['customer_id']
              self.settings['subscription']['prior_customer_ids'] ||= []
              self.settings['subscription']['prior_customer_ids'] << self.settings['subscription']['customer_id']
            end
            self.settings['subscription']['customer_id'] = args['customer_id']
          end
          if args['gift_id']
            self.settings['subscription']['gift_ids'] ||= []
            self.settings['subscription']['gift_ids'] << args['gift_id']
          end
          self.settings['purchase_bounced'] = false
          self.settings['subscription']['modeling_only'] = ['slp_long_term_free', 'slp_monthly_free'].include?(args['plan_id'])
          self.settings['subscription']['limited_premium_purchase'] = !!(args['plan_id'] && args['plan_id'].match(/^slp_long_term/) && !args['plan_id'].match(/free/))
          self.settings['subscription']['eval_account'] = !!(args['plan_id'] || '').match(/^eval/)

          self.settings['pending'] = false unless self.settings['subscription']['modeling_only']

          role = (args['plan_id'] && args['plan_id'].match(/^slp/)) ? 'supporter' : 'communicator'
          self.settings['subscription']['token_summary'] = args['token_summary']

          if ['AppPrePurchase', 'com.mycoughdrop.paidcoughdrop', 'CoughDropiOSPlusExtras', 'CoughDropiOSBundle', 'CoughDropiOSEval', 'CoughDropiOSSLP'].include?(args['token_summary'])
            # remember long-term in-app purchases for the user so we don't have to re-validate them every time
            self.settings['subscription']['iap_purchases'] ||= []
            self.settings['subscription']['iap_purchases'] << args['token_summary'] 
            self.settings['subscription']['iap_purchases'].uniq!
          end
          self.settings['subscription']['last_purchased'] = Time.now.iso8601
          self.settings['subscription']['last_purchase_plan_id'] = args['plan_id']
          self.settings['subscription']['last_purchase_id'] = args['purchase_id']
          if args['plan_id'] != 'slp_long_term_free' && args['plan_id'] != 'slp_monthly_free'
            self.settings['subscription']['last_paid_purchase_plan_id'] = args['plan_id']
            self.settings['subscription']['last_paid_purchase_id'] = args['purchase_id']
            self.settings['subscription']['last_paid_purchase_amount'] = args['purchase_amount']
          end
          PurchaseToken.map("purchase.#{args['source_id']}.#{args['purchase_id']}", args['device_id'], self)
          self.settings['subscription']['discount_code'] = args['discount_code'] if args['discount_code']
          self.settings['subscription']['last_purchase_seconds_added'] = args['seconds_to_add']
          self.settings['subscription']['purchase_amount'] = args['purchase_amount']
          self.settings['preferences']['role'] = role
          self.settings['preferences']['progress'] ||= {}
          self.settings['preferences']['progress']['subscription_set'] = true
          self.expires_at = [self.expires_at, Time.now].compact.max
          self.expires_at += args['seconds_to_add'].to_i
          self.settings['subscription']['expiration_source'] = 'purchase' if args['seconds_to_add'].to_i > 0

          if ((self.settings['premium_voices'] || {})['trial_voices'] || []).length > 0
          if self.full_premium?
            # When a user fully subscribes, activate any trialed premium voices
            self.settings['premium_voices']['trial_voices'].each do |v| 
              self.track_voice_added(v['i'], v['s']) 
              self.settings['premium_voices']['allowed'] = [self.settings['premium_voices']['allowed'] || 0, self.default_premium_voices['allowed']].max
            end
            self.settings['premium_voices'].delete('trial_voices')
          elsif self.modeling_only? && self.settings['premium_voices']
            self.settings['premium_voices']['allowed'] = self.settings['premium_voices']['extra'] || 0
            self.settings['premium_voices']['claimed'] = (self.settings['premium_voices']['claimed'] || [])[0, self.settings['premium_voices']['allowed']]
            self.settings['premium_voices'].delete('trial_voices')
          end
          end
        end
      
        self.assert_current_record!
        self.save_with_sync('purchase')
        self.schedule(:remove_supervisors!) if self.premium_supporter? || self.modeling_only?
      end
    else
      res = false
    end
    self.schedule_audit_protected_sources
    res
  rescue ActiveRecord::StaleObjectError
    return false
  end
  
  def redeem_gift_token(code)
    Purchasing.redeem_gift(code, self)
  end

  def track_voice_added(voice_id, system_name)
    data = {
      :user_id => self.global_id,
      :user_name => self.user_name,
      :voice_id => voice_id,
      :timestamp => Time.now.to_i,
      :system => system_name
    }
    AuditEvent.create!(:event_type => 'voice_added', :summary => "#{self.user_name} added #{voice_id}", :data => data)
  end

  def process_subscription_token(token, type, code=nil)
    if type == 'unsubscribe'
      Purchasing.unsubscribe(self)
    elsif type == 'extras'
      Purchasing.purchase_symbol_extras(token, {'user_id' => self.global_id})
    else
      Purchasing.purchase(self, token, type, code)
    end
  end

  def verify_receipt(receipt_data)
    Purchasing.verify_receipt(self, receipt_data)
  end
  
  def subscription_override(type, user_id=nil)
    if type == 'never_expires'
      self.log_subscription_event(:log => 'subscription override: free forever', :args => {user_id: self.global_id, author_id: user_id})
      self.process({}, {'pending' => false, 'premium_until' => 'forever'})
    elsif type == 'eval'
      self.log_subscription_event(:log => 'subscription override: eval account', :args => {user_id: self.global_id, author_id: user_id})
      self.settings['preferences'] ||= {}
      self.settings['preferences']['role'] = 'communicator'
      self.update_subscription({
        'subscribe' => true,
        'subscription_id' => 'free_eval',
        'token_summary' => "Manually-set Eval Account",
        'plan_id' => 'eval_monthly_granted'
      })
    elsif type == 'add_voice'
      self.log_subscription_event(:log => 'subscription override: add premium voice', :args => {user_id: self.global_id, author_id: user_id})
      self.allow_additional_premium_voice!
    elsif type == 'force_logout'
      self.devices.each{|d| d.invalidate_keys! }
      true
    elsif type == 'enable_extras'
      self.log_subscription_event(:log => 'subscription override: extras enabled', :args => {user_id: self.global_id, author_id: user_id})
      User.purchase_extras({
        'user_id' => self.global_id,
        'premium_symbols' => true,
        'source' => 'admin_override'
      })
    elsif type == 'supporter_credit'
      self.log_subscription_event(:log => 'subscription override: add supporter credit', :args => {user_id: self.global_id, author_id: user_id})
      User.purchase_extras({
        'user_id' => self.global_id,
        'premium_supporters' => 1,
        'source' => 'admin_override'
      })
    elsif type == 'restore'
      self.update_subscription({
        'purchase' => true,
        'purchase_id' => 'restore'        
      })
    elsif type == 'check_remote'
      Purchasing.reconcile_user(self.global_id, false)
      # TODO: second arg set to true for actual reconciliation
    elsif type == 'add_1' || type == 'communicator_trial' || type == 'add_5_years'
      self.log_subscription_event(:log => "subscription override: #{type}", :args => {user_id: self.global_id, author_id: user_id})
      if type == 'communicator_trial'
        self.settings['preferences'] ||= {}
        self.settings['preferences']['role'] = 'communicator'
        self.settings['pending'] = false
        self.save_with_sync('trial')
        self.update_subscription({
          'subscribe' => true,
          'subscription_id' => 'free_trial',
          'token_summary' => "Manually-set Communicator Account",
          'plan_id' => 'monthly_granted'
        })
      end
      self.expires_at ||= Time.now
      if self.expires_at
        self.expires_at = [self.expires_at, Time.now].max + (type == 'add_5_years' ? 5.years : 1.month)
        self.settings ||= {}
        self.settings['subscription_adders'] ||= []
        self.settings['subscription_adders'] << [user_id, Time.now.to_i]
        self.settings['pending'] = false
        self.save_with_sync('expires')
      end
    elsif type == 'manual_modeler'
      self.log_subscription_event(:log => 'subscription override: manual modeling', :args => {user_id: self.global_id, author_id: user_id})
      self.settings['preferences'] ||= {}
      self.settings['preferences']['role'] = 'supporter'
      self.update_subscription({
        'subscribe' => true,
        'subscription_id' => 'free',
        'token_summary' => "Manually-set Modeling Account",
        'plan_id' => 'slp_monthly_free'
      })
    elsif type == 'manual_supporter' || type == 'granted_supporter'
      self.log_subscription_event(:log => "subscription override: #{type}", :args => {user_id: self.global_id, author_id: user_id})
      self.settings['preferences'] ||= {}
      self.settings['preferences']['role'] = 'supporter'
      self.update_subscription({
        'subscribe' => true,
        'subscription_id' => "free-#{Time.now.iso8601}",
        'token_summary' => (type == 'manual_supporter') ? "Manually-set Supporter Account" : "Communicator-Granted Supporter Account",
        'plan_id' => 'slp_monthly_granted'
      })
    else
      false
    end
  end
  
  def subscription_event(args)
    self.log_subscription_event(:log => 'subscription event triggered remotely', :args => args)
    if args['purchase_failed']
      self.settings['purchase_bounced'] = true
      self.save
      SubscriptionMailer.schedule_delivery(:purchase_bounced, self.global_id)
      return true
    elsif args['purchase_succeeded']
      self.settings['purchase_bounced'] = false
      self.save
    elsif args['purchase']
      is_new = update_subscription(args)
      if is_new
        if args['plan_id'] == 'gift_code'
          SubscriptionMailer.schedule_delivery(:gift_redeemed, args['gift_id'])
          self.log_subscription_event(:log => 'gift notification triggered')
          SubscriptionMailer.schedule_delivery(:gift_seconds_added, args['gift_id'])
          SubscriptionMailer.schedule_delivery(:gift_updated, args['gift_id'], 'redeem')
        else
          if self.premium_supporter?
            SubscriptionMailer.schedule_delivery(:supporter_purchase_confirmed, self.global_id)
          elsif self.eval_account?
            SubscriptionMailer.schedule_delivery(:eval_purchase_confirmed, self.global_id)
          else
            SubscriptionMailer.schedule_delivery(:purchase_confirmed, self.global_id)
          end
          self.log_subscription_event(:log => 'purchase notification triggered')
          SubscriptionMailer.schedule_delivery(:new_subscription, self.global_id)
        end
      end
      return is_new
    elsif args['subscribe']
      is_new = update_subscription(args)
      if is_new
        SubscriptionMailer.schedule_delivery(:purchase_confirmed, self.global_id) 
        self.log_subscription_event(:log => 'subscription notification triggered')
        SubscriptionMailer.schedule_delivery(:new_subscription, self.global_id) 
      end
      return is_new
    elsif args['unsubscribe']
      is_new = update_subscription(args)
      SubscriptionMailer.schedule_delivery(:subscription_expiring, self.global_id) if is_new
      return is_new
    elsif args['chargeback_created']
      SubscriptionMailer.schedule_delivery(:chargeback_created, self.global_id)
      return true
    end
    true
  end

  def premium_supporter_grants
    total = (self.settings['subscription'] || {})['purchased_supporters'] || 0
    used = ((self.settings['subscription'] || {})['allotted_supporter_ids'] || []).length
    return total - used
  end

  def grant_premium_supporter(user)
    return false unless self.premium_supporter_grants > 0
    user.settings['preferences']['role'] = 'supporter'
    if user.billing_state != :premium_supporter
      user.subscription_override('granted_supporter')
      self.settings['subscription']['allotted_supporter_ids'] ||= []
      self.settings['subscription']['allotted_supporter_ids'] << user.global_id
      self.settings['subscription']['allotted_supporter_ids'].uniq!
      self.save!
      return true
    else
      return false
    end
  end

  def assert_eval_settings
    if self.eval_account?
      self.settings['eval_reset'] ||= {}
      self.settings['eval_reset']['email'] ||= self.settings['email']
      self.settings['subscription'] ||= {}
      if !self.settings['subscription']['eval_expires']
        duration = self.eval_duration
        self.settings['subscription']['eval_started'] ||= Time.now.iso8601
        self.settings['subscription']['eval_expires'] = duration.days.from_now.iso8601
        self.save
      end
    end
  end

  def reset_eval(current_device_id, opts={})
    current_device = Device.find_by_global_id(current_device_id)
    return false unless current_device && self.eval_account?
    duration = self.eval_duration
    prior_email = self.settings['email']
    self.settings['subscription'] ||= {}
    self.settings['subscription']['eval_account'] = true
    # reset the eval expiration clock
    self.settings['subscription']['eval_started'] = Time.now.iso8601
    self.settings['subscription']['eval_expires'] = duration.days.from_now.iso8601
    # clear/reset preferences (remember them so they can be transferred
    self.settings['last_preferences'] = self.settings['preferences'] || {}
    self.settings['preferences'] = nil
    self.settings = self.settings.slice('last_preferences', 'subscription', 'eval_reset', 'boards_shared_with_me', 'confirmation_log', 'feature_flags', 'password', 'premium_voices', 'public')
    self.settings['all_home_boards'] = nil
    self.generate_defaults

    # DON'T flush org links
    Flusher.flush_user_content(self.global_id, self.user_name, current_device, true)
    # restore the last home board, in case it's a default (can be changed easily)
    if self.settings['last_preferences']['home_board'] && self.settings['last_preferences']['home_board']['key'] && !self.settings['last_preferences']['home_board']['key'].match(/^#{self.user_name}\/}/)
      self.settings['preferences']['home_board'] = self.settings['last_preferences']['home_board']
    end
    if self.settings['eval_reset']
      self.settings['email'] = self.settings['eval_reset']['email'] if self.settings['eval_reset']['email']
      self.settings['preferences']['home_board'] = self.settings['eval_reset']['home_board'] if self.settings['eval_reset']['home_board']
      self.settings['preferences']['password'] = self.settings['eval_reset']['password'] if self.settings['eval_reset']['pasword']
    end
    if opts
      self.settings['email'] = opts['email'] if !opts['email'].blank?
      if opts['expires']
        self.settings['subscription']['eval_expires'] = Date.parse(opts['expires']).iso8601 rescue nil
      end
      if !opts['password'].blank?
        self.generate_password(opts['password'])
      end
      org_link = Organization.attached_orgs(self, true).detect{|o| o['type'] == 'user' && o['eval'] && !o['pending']}
      org = org_link && org_link['org']
      if org_link && !opts['home_board_key']
        opts['home_board_key'] = (org.home_board_keys || [])[0]
      end
      if !opts['home_board_key'].blank?
        board = Board.find_by_path(opts['home_board_key'])
        if board && (board.public || (org && (org.home_board_keys || []).include?(opts['home_board_key'])))
          symbols = opts['symbol_library'] || (org && org.settings['preferred_symbols']) || 'original'
          self.process_home_board({'id' => board.global_id, 'copy' => true, 'symbol_library' => symbols}, {'updater' => board.user, 'org' => org, 'async' => false})
        end
      end
    end
    # log out of all other devices (and remove them for privacy)
    self.devices.select{|d| d != current_device}.each{|d| d.destroy }
    # enable logging by default
    self.settings['preferences']['logging'] = true
    self.save_with_sync('reset_eval')
    if self.settings['email'] != prior_email
      UserMailer.schedule_delivery(:eval_welcome, self.global_id)
    end
    true
  end
  
  def transfer_eval_to(destination_user_id, current_device_id, end_eval=true)
    destination_user = User.find_by_global_id(destination_user_id)
    current_device = Device.find_by_global_id(current_device_id)
    return false unless destination_user && current_device && self.eval_account?
    device_key = current_device.unique_device_key
    devices = destination_user.settings['preferences']['devices'] || {}
    devices[device_key] = self.settings['preferences']['devices'][device_key] if self.settings['preferences']['devices'][device_key]
    destination_user.settings['preferences'] = destination_user.settings['preferences'].merge(self.settings['preferences'])
    destination_user.settings['preferences']['devices'] = devices
    destination_user.save_with_sync('transfer_eval')
    # transfer usage logs to the new user
    eval_start = Time.parse((self.settings['subscription'] || {})['eval_started'] || 60.days.ago.iso8601)
    LogSession.where(user_id: self.id).where(log_type: ['session', 'daily_use', 'note', 'assessment', 'eval', 'modeling_activities', 'activities', 'journal']).where(['started_at > ?', eval_start]).update_all(user_id: destination_user.id)
    Flusher.transfer_user_content(self.global_id, self.user_name, destination_user.global_id, destination_user.user_name)
    # TODO: transfer daily_use data across as well
    WeeklyStatsSummary.where(user_id: self.id).where(['created_at > ?', eval_start]).each do |summary|
      summary.schedule(:update!)
    end
    WeeklyStatsSummary.where(user_id: destination_user.id).where(['created_at > ?', eval_start]).each do |summary|
      summary.schedule(:update!)
    end
    if end_eval
      return self.reset_eval(current_device.global_id)
    end
    true
  end
  
  def extend_eval(extension, extending_user)
    return false unless self.eval_account?
    if (extending_user != self && self.allows?(extending_user, 'supervise')) || (self.supervisors.length == 0 && !Organization.managed?(self))
      self.settings['subscription'].delete('eval_extended')
      extend_date = (Date.parse(extension).to_time + 12.hours) rescue nil
      self.settings['subscription']['eval_expires'] = [[extend_date, 1.week.from_now].compact.max, 90.days.from_now].min.iso8601
    elsif !self.settings['subscription']['eval_extended']
      current = (self.settings['subscription'] && Date.parse(self.settings['subscription']['eval_expires'])) rescue nil
      self.settings['subscription']['eval_expires'] = ((current || Time.now) + 1.week).iso8601
      self.settings['subscription']['eval_extended'] = true
    end
    self.settings['subscription']['eval_expires']
  end

  def eval_duration
    (self.settings['eval_reset'] || {})['duration'] || self.class.default_eval_duration
  end
  
  def purchase_credit_duration
    # long-term purchase, org-sponsored, or subscription duration for the current user
    supporter_ok = self.supporter_role?
    past_tally = ((self.settings || {})['past_purchase_durations'] || []).map{|d| (supporter_ok || (d['role'] || 'communicator') == 'communicator') ? (d['duration'] || 0) : 0 }.sum
    return past_tally if past_tally > 2.years
    started = nil
    # for a long-term purchase, track from when the purchase happened
    if self.settings['subscription'] && self.settings['subscription']['last_purchased'] && self.expires_at
      # don't use an active supporter purchase as credit for communicator
      if self.supporter_role? || !((self.settings['subscription'] || {})['last_purchase_plan_id'] || '').match(/^slp/)
        started = Time.parse(self.settings['subscription']['last_purchased']) rescue nil
      end
    end
    if self.settings['subscription'] && self.settings['subscription']['started']
      # for a recurring subscription, track from when the subscription started
      started = Time.parse(self.settings['subscription']['started']) rescue nil
    elsif self.org_sponsored?
      # for an org sponsorship, track the duration of the sponsorship
      sponsor_dates = UserLink.links_for(self).select{|l| l['type'] == 'org_user' && l['state']['sponsored'] == true}.map{|l| l['state']['added'] }
      started = Time.parse(sponsor_dates.sort.first) rescue nil
    elsif self.org_supporter? && self.supporter_role?
      sponsor_dates = UserLink.links_for(self).select{|l| l['type'] == 'org_supervisor'}.map{|l| l['state']['added'] }
      started = Time.parse(sponsor_dates.sort.first) rescue nil
    end
    tally = past_tally

    from_purchase = self.settings['subscription']['expiration_source'] == 'purchase' || (self.settings['subscription']['last_purchase_plan_id'] && !self.settings['subscription']['last_purchase_plan_id'].match(/free/))
    if from_purchase || !self.expires_at
      end_time = (self.expires_at || Time.now)
      # don't use an active supporter purchase as credit for communicator
      end_time = Time.now if self.communicator_role? && (self.settings['subscription']['last_purchase_plan_id'] || '').match(/^slp/)
      tally += end_time.to_i - [started, Time.now].compact.min.to_i
    end
    return tally
  end
  
  def fully_purchased?(shallow=false)
    return true if self.settings && self.settings['subscription'] && self.settings['subscription']['never_expires']
    # long-term purchase, org-sponsored, or subscription for at least 2 years
    supporter_ok = self.supporter_role?
    past_tally = ((self.settings || {})['past_purchase_durations'] || []).map{|d| (supporter_ok || (d['role'] || 'communicator') == 'communicator') ? (d['duration'] || 0) : 0 }.sum
    return true if past_tally > (2.years - 1.week)
    return false if shallow
    duration = self.purchase_credit_duration
    return duration > (2.years - 1.week)
  end

  def supporter_role?
    self.settings && self.settings['preferences'] && self.settings['preferences']['role'] == 'supporter'
  end
  
  def communicator_role?
    !self.supporter_role?
  end
  
  def org_sponsored?
    Organization.sponsored?(self)
  end

  def org_supporter?(premium=false)
    Organization.supervisor?(self, premium)
  end

  def billing_state(force_type=nil)
    self.settings ||= {}
    self.settings['subscription'] ||= {}
    if (self.communicator_role? && force_type == nil) || force_type == 'communicator'
      return :never_expires_communicator if self.settings['subscription']['never_expires']
      return :eval_communicator if self.settings['subscription']['eval_account']
#      return :eval_communicator if self.settings['subscription']['plan_id'] == 'eval_monthly_free'
      return :subscribed_communicator if self.settings['subscription']['started']
      return :org_sponsored_communicator if self.org_sponsored?
      last_plan_id = self.settings['subscription']['last_purchase_plan_id'] || ''
      if self.expires_at && self.expires_at > Time.now && !last_plan_id.match(/^slp/)
        if self.settings['subscription']['expiration_source']
          return :trialing_communicator if self.settings['subscription']['expiration_source'] == 'free_trial'
          return :long_term_active_communicator if self.settings['subscription']['last_purchase_plan_id'] && !self.settings['subscription']['last_purchase_plan_id'].match(/free/)
          return :grace_period_communicator #if self.settings['subscription']['expiration_source'] == 'grace_period'
        else
          # legacy logic
          return :long_term_active_communicator if self.settings['subscription']['last_purchase_plan_id'] && !self.settings['subscription']['last_purchase_plan_id'].match(/free/)
          return :trialing_communicator if !self.created_at || self.created_at > 60.days.ago
          return :grace_period_communicator
        end
      end
      return :lapsed_communicator if self.fully_purchased?
      return :expired_communicator
    else
      # eval accounts set as supporters are limited to modeling-only
      # but other paid accounts can switch to premium supporter if they like
      return :org_sponsored_supporter if self.settings['possibly_premium_supporter'] && self.org_supporter?(true)
      return :premium_supporter if self.settings['subscription']['never_expires']
      return :premium_supporter if self.fully_purchased?
      return :premium_supporter if self.settings['subscription']['started']
      return :premium_supporter if self.legacy_free_premium?
      return :premium_supporter if (self.settings['subscription']['plan_id'] || '').match(/_granted$/)
      if self.expires_at && self.expires_at > Time.now
        if self.settings['subscription']['expiration_source']
          if self.settings['possibly_premium_supporter'] == nil && rand(5) == 0 && self.org_supporter?(true)
            # Race condition was preventing this value from getting saved occasionally
            self.settings['possibly_premium_supporter'] = true
            self.save
            return :org_sponsored_supporter
          end
          return :trialing_supporter if self.settings['subscription']['expiration_source'] == 'free_trial'
          return :premium_supporter if self.settings['subscription']['last_purchase_plan_id'] && !self.settings['subscription']['last_purchase_plan_id'].match(/free/)
          return :grace_period_supporter unless self.org_sponsored?
        else
          # legacy logic
          return :trialing_supporter if !self.created_at || self.created_at > 60.days.ago
          return :premium_supporter if self.settings['subscription']['last_purchase_plan_id'] && !self.settings['subscription']['last_purchase_plan_id'].match(/free/)
          return :grace_period_supporter
        end
      end
      return :premium_supporter if self.org_sponsored?
      return :org_supporter if self.org_supporter? || Organization.manager?(self)
      return :modeling_only
    end
  end
  
  def eval_account?
    return self.billing_state == :eval_communicator
  end
    
  def never_expires?
    return self.billing_state == :never_expires_communicator
  end

  def recurring_subscription?
    return self.billing_state == :subscribed_communicator
  end

  def long_term_purchase?
    return self.billing_state == :long_term_active_communicator
  end

  def modeling_only?
    return self.billing_state == :modeling_only
    # # Independent variable
    # # Any non-purchased, non-trial supporter is modeling_only
    # self.settings['subscription'] ||= {}
    # self.settings['subscription']['limited_premium_purchase'] ||= self.settings['subscription']['free_premium'] if self.settings['subscription']['free_premium']
    # return true if self.settings['subscription']['modeling_only']
    # return true if self.supporter_role? && self.expires_at && self.expires_at < Time.now && !self.settings['subscription']['limited_premium_purchase']
    # return false
  end

  def legacy_free_premium?
    self.created_at && self.created_at < Date.parse('June 15, 2020') && self.settings && self.settings['subscription'] && self.settings['subscription']['free_premium']
  end

  def lapsed_communicator?
    return self.billing_state == :lapsed_communicator
    # # true for a communicator who has paid and expired
    # !!(self.expires_at && self.expires_at < Time.now && self.communicator_role? && self.fully_purchased?)
  end

  def expired_communicator?
    return self.billing_state == :expired_communicator
    # !!(self.expires_at && self.expires_at < Time.now && self.communicator_role? && !self.fully_purchased?)
  end

  def premium_supporter?
    return [:trialing_supporter, :grace_period_supporter, :premium_supporter, :org_supporter, :org_sponsored_supporter].include?(self.billing_state)
    # # Returns true if this user does not have a full-premium
    # # purchase, but has limited-premium enabled (i.e. bought)
    
    # fully_purchased = self.fully_purchased?
    # # Org-sponsored users have limited-premium access
    # # so long as they are in the org, and not if they
    # # also have more powerful permissions granted.
    # return true if self.org_supporter? && !self.full_premium_or_fully_purchased?
    # # Supporters who have paid for the app are also marked as premium 
    # return true if self.supporter_role? && fully_purchased
    # # Side effects: If the supported account's trial expires,
    # # auto-set it to be modeling-only. If the account was in 
    # # a grace period and ever had a purchase/extended-sponsors, 
    # # auto-set it to paid supporter (limited_premium_purchase)
    # if self.supporter_role? && self.expires_at && self.expires_at < Time.now && !self.long_term_purchase?
    #   self.schedule(:subscription_override, fully_purchased ? 'manual_supporter' : 'manual_modeler')
    #   return fully_purchased
    # # elsif self.supporter_registration? && self.communicator_role? && self.expires_at && self.expires_at < Time.now && !self.full_premium_or_fully_purchased?
    # #   self.schedule(:subscription_override, 'manual_modeler')
    # #   return false
    # end
    # return false if self.modeling_only?
    # if self.expires_at && !self.long_term_purchase? && fully_purchased && self.supporter_role?
    #   return true
    # end
    # self.settings['subscription'] ||= {}
    # self.settings['subscription']['limited_premium_purchase'] ||= self.settings['subscription']['free_premium'] if self.settings['subscription']['free_premium']
    # !!(self.settings && self.settings['subscription'] && self.settings['subscription']['limited_premium_purchase'])
  end

  # def full_premium_or_fully_purchased?
  #   !!(never_expires? || self.recurring_subscription? || self.long_term_purchase? || self.fully_purchased?(true) || self.org_sponsored? )
  # end
  
  def grace_period?
    return [
      :trialing_communicator, 
      :grace_period_communicator, 
      :trialing_supporter, 
      :grace_period_supporter
    ].include?(self.billing_state)
    # true for the initial trial period, as well as for
    # any intermediate expires_at updates such as the
    # grace period you get after unsubscribing or being 
    # removed from an org
    # Checks full_premium_or_fully_purchased?
    # self.settings ||= {}
    # self.settings['subscription'] ||= {}
    # return false if self.never_expires? || self.recurring_subscription? || self.org_sponsored?
    # if self.expires_at && self.expires_at > Time.now
    #   if self.settings['subscription']['expiration_source']
    #     return self.settings['subscription']['expiration_source'] != 'purchase'
    #   else
    #     purchased_expiration = self.settings['subscription']['last_purchase_plan_id'] && !self.settings['subscription']['last_purchase_plan_id'].match(/free/)
    #     return !purchased_expiration
    #   end
    # end
    # return false
    # !!(self.expires_at && self.expires_at > Time.now && !self.full_premium? && !self.org_supporter?)
  end
  
  def any_premium_or_grace_period?(include_lapsed=false)
    state = self.billing_state
    return true if include_lapsed && state == :lapsed_communicator
    return [
      :never_expires_communicator,
      :eval_communicator,
      :subscribed_communicator,
      :trialing_communicator,
      :long_term_active_communicator,
      :grace_period_communicator,
      :org_sponsored_communicator,
      :premium_supporter,
      :trialing_supporter,
      :grace_period_supporter,
      :org_sponsored_supporter,
      :org_supporter
    ].include?(self.billing_state)
    # Some kind of purchase or access granted, either
    # as a communicator or paid supervisor
    # Checks full_premium_or_fully_purchased?
    # !!(self.full_premium_or_fully_purchased? || self.grace_period? || self.premium_supporter? || self.org_supporter?)
  end

  def full_premium?(force_state=false)
    return [
      :never_expires_communicator, 
      :eval_communicator, 
      :subscribed_communicator, 
      :long_term_active_communicator,
      :org_sponsored_communicator,
      :org_sponsored_supporter
    ].include?(self.billing_state(force_state ? 'communicator' : nil))
    # full_premium means paid for and active cloud extras
    # * not in a grace period *
    # Checks full_premium_or_fully_purchased?
    # !!(self.full_premium_or_fully_purchased? && !self.lapsed_communicator? && !self.premium_supporter? && !self.grace_period?)
  end  

  def extras_for_org?(org)
    self.settings ||= {}
    extras = (self.settings['subscription'] || {})['extras'] || {}
    return !!(org && extras && extras['enabled'] && extras['source'] == 'org_added' && extras['org_id'] == org.global_id)
  end
  
  def subscription_hash
    json = {}
    self.settings['subscription'] ||= {}
    self.settings['subscription']['limited_premium_purchase'] ||= self.settings['subscription']['free_premium'] if self.settings['subscription']['free_premium']
    billing_state = self.billing_state
    json['billing_state'] = billing_state
    json['timestamp'] = Time.now.to_i
    # active means a non-expired, active purchase of some kind,
    # an active subscription, unexpired long-term-purchase,
    # premium supporter, paid eval, org sponsorship
    if billing_state == :never_expires_communicator
      # manually-set to never expire as a full communicator
      json['never_expires'] = true
      json['active'] = true
    elsif billing_state == :org_sponsored_communicator
      # currently-sponsored as a communicator
      json['active'] = true
      json['org_sponsored'] = true
    elsif billing_state == :expired_communicator
      sup_billing_state = self.billing_state('supporter')
      json['premium_supporter_as_communicator'] = true if [:premium_supporter].include?(sup_billing_state)
    elsif billing_state == :eval_communicator
      json['active'] = true
      json['eval_account'] = true
      json['plan_id'] = self.settings['subscription']['last_purchase_plan_id']
      json['eval_started'] = self.settings['subscription']['eval_started']
      json['eval_expires'] = self.settings['subscription']['eval_expires']
      json['eval_extendable'] = !self.settings['subscription']['eval_extended']
    elsif self.premium_supporter?
      # currently-added as an org supervisor
      json['active'] = true
      json['premium_supporter'] = true
      com_billing_state = self.billing_state('communicator')
      json['premium_supporter_plus_communicator'] = true if billing_state == :org_sponsored_supporter || [:never_expires_communicator, :subscribed_communicator, :long_term_active_communicator].include?(com_billing_state)
      json['subscribed_as_communicator'] = true if [:subscribed_communicator].include?(com_billing_state)
      json['never_expires'] = true if self.settings['subscription']['never_expires']
      json['org_sponsored'] = true if com_billing_state == :org_sponsored_communicator
      json['free_premium'] = json['premium_supporter']
      json['expires'] = self.expires_at && self.expires_at.iso8601 if self.billing_state == :trialing_supporter
      json['grace_period'] = true if self.grace_period?
      json['grace_trial_period'] = true if json['grace_period'] && ([:trialing_communicator,:trialing_supporter].include?(billing_state) || [:trialing_communicator,:trialing_supporter].include?(com_billing_state))
    else
      if [:long_term_active_communicator, :trialing_communicator, :grace_period_communicator, :trialing_supporter, :grace_period_supporter].include?(billing_state) #!self.eval_account? && !self.premium_supporter?
        json['expires'] = self.expires_at && self.expires_at.iso8601
      end
      json['grace_period'] = true if self.grace_period?
      json['grace_trial_period'] = true if json['grace_period'] && [:trialing_communicator,:trialing_supporter].include?(billing_state)
      json['modeling_only'] = true if self.modeling_only?
      if billing_state == :subscribed_communicator
        # active subcsription for a full communicator
        json['active'] = true
        json['started'] = self.settings['subscription']['started']
        json['plan_id'] = self.settings['subscription']['plan_id']
      elsif billing_state == :long_term_active_communicator
        # non-expired full communicator purchase,
        json['active'] = true
        json['purchased'] = self.settings['subscription']['customer_id'] != 'free'
        json['plan_id'] = self.settings['subscription']['last_purchase_plan_id']
      elsif billing_state == :lapsed_communicator
        json['lapsed_communicator'] = self.lapsed_communicator?
        json['free_premium'] = true
      end
    end
    if self.settings['subscription']['purchased_supporters'].to_i > 0
      json['purchased_supporters'] = self.settings['subscription']['purchased_supporters'].to_i
      json['available_supporters'] = self.premium_supporter_grants
    end
    json['iap_purchases'] = self.settings['subscription']['iap_purchases'] if !self.settings['subscription']['iap_purchases'].blank?
    json['fully_purchased'] = true if self.fully_purchased?
    json['free_premium'] = true if self.legacy_free_premium?
    json['extras_enabled'] = true if self.settings['subscription']['extras'] && self.settings['subscription']['extras']['enabled']
    # Allow premium symbols during the free trial, with a note about temporary status
    json['extras_enabled'] = false if (json['grace_trial_period'] || billing_state == :trialing_supporter) && !self.settings['extras_disabled']
    if json['plan_id']
      Purchasing.plan_map.each do |frontend_id, backend_id|
        json['plan_id'] = frontend_id if json['plan_id'] == backend_id
      end
    end
    json
  end
  
  def log_subscription_event(hash)
    hash[:time] = Time.now.to_i
    AuditEvent.create({
      record_id: self.record_code,
      event_type: 'subscription_event',
      data: hash
    })
  end
  
  def subscription_events
    AuditEvent.where(event_type: 'subscription_event', record_id: self.record_code).order('id ASC').map{|e| e.data }
  end
      
  module ClassMethods  
    def check_for_subscription_updates
      alerts = {:approaching => 0, :approaching_emailed => 0, :upcoming => 0, :upcoming_emailed => 0, :expired => 0, :expired_emailed => 0, :expired_follow_up => 0, :recent_less_active => 0, :pending_deletes => 0}
      
      # send out a one-month and three-month warning for long-term purchase subscriptions
      [1, 3].each do |num|
        approaching_expires = User.where(['expires_at > ? AND expires_at < ?', num.months.from_now - 0.5.days, num.months.from_now + 0.5.days])
        approaching_expires.each do |user|
          if [:long_term_active_communicator, :grace_period_communicator, :lapsed_communicator].include?(user.billing_state)
            alerts[:approaching] += 1
            user.settings['subscription'] ||= {}
            last_message = Time.parse(user.settings['subscription']['last_approaching_notification']) rescue Time.at(0)
            if last_message < 1.week.ago
              SubscriptionMailer.deliver_message(:expiration_approaching, user.global_id)
              user.update_setting({
                'subscription' => {'last_approaching_notification' => Time.now.iso8601}
              })
              alerts[:approaching_emailed] += 1
            end
          end
        end
      end

      upcoming_expires = User.where(['expires_at > ? AND expires_at < ?', 6.hours.from_now, 1.week.from_now])
      # send out a warning notification 1 week before, and another one the day before,
      # to all the ones that haven't been warned yet for this cycle
      upcoming_expires.each do |user|
        # only notify expired communicators
        next if !user.communicator_role? || user.eval_account? || [:never_expires_communicator, :subscribed_communicator, :long_term_active_communicator, :org_sponsored_communicator].include?(user.billing_state)
        alerts[:upcoming] += 1
        user.settings['subscription'] ||= {}
        last_day = Time.parse(user.settings['subscription']['last_expiring_day_notification']) rescue Time.at(0)
        last_week = Time.parse(user.settings['subscription']['last_expiring_week_notification']) rescue Time.at(0)
        if user.expires_at <= 36.hours.from_now && last_day < 1.week.ago
          SubscriptionMailer.deliver_message(:one_day_until_expiration, user.global_id)
          user.update_setting({
            'subscription' => {'last_expiring_day_notification' => Time.now.iso8601}
          })
          alerts[:upcoming_emailed] += 1
        elsif user.expires_at > 4.days.from_now && last_week < 1.week.ago
          SubscriptionMailer.deliver_message(:one_week_until_expiration, user.global_id)
          user.update_setting({
            'subscription' => {'last_expiring_week_notification' => Time.now.iso8601}
          })
          alerts[:upcoming_emailed] += 1
        end
      end
      
      now_expired = User.where(['expires_at > ? AND expires_at < ?', 3.days.ago, Time.now])
      # send out an expiration notification to all the ones that haven't been notified yet
      now_expired.each do |user|
        # only notify expired communicators
        next if !user.communicator_role? || user.eval_account? || [:never_expires_communicator, :subscribed_communicator, :long_term_active_communicator, :org_sponsored_communicator].include?(user.billing_state)
        alerts[:expired] += 1
        user.settings['subscription'] ||= {}
        last_expired = Time.parse(user.settings['subscription']['last_expired_notification']) rescue Time.at(0)
        if user.expires_at < Time.now && last_expired < 3.days.ago
          SubscriptionMailer.deliver_message(:subscription_expired, user.global_id)
          user.update_setting({
            'subscription' => {'last_expired_notification' => Time.now.iso8601}
          })
          alerts[:expired_emailed] += 1
        end
      end
      
      recently_expired = User.where(['expires_at > ? AND expires_at < ?', 3.weeks.ago, 2.weeks.ago])
      recently_expired.each do |user|
        user.settings['subscription'] ||= {}
        last_recently_expired = Time.parse(user.settings['subscription']['last_expired_follow_up']) rescue Time.at(0)
        if last_recently_expired < 6.months.ago
          if user.communicator_role?
            # message asking why they didn't go with it
          else
            # if inactive, message asking why they aren't super stoked about it
          end
          alerts[:expired_follow_up] += 1
        end
      end
      
      recently_registered = User.where(['created_at > ? AND created_at < ?', 10.days.ago, 5.days.ago])
      recent_but_less_active = recently_registered.select{|u| !u.settings['preferences']['logging'] || 
                                  u.devices.all?{|d| d.updated_at < 4.days.ago} || 
                                  !u.settings['preferences']['home_board'] || 
                                  (u.settings['preferences']['role'] == 'supporter' && u.supervised_user_ids.empty?)
                            }
      recent_but_less_active.each do |user|
        user.settings['subscription'] ||= {}
        last_reminded = Time.parse(user.settings['subscription']['last_logging_reminder_notification']) rescue Time.at(0)
        if last_reminded < 7.days.ago
          UserMailer.deliver_message(:usage_reminder, user.global_id)
          UserMailer.schedule_later_delivery(:welcome_confirm_registration, user.global_id)

          user.update_setting({
            'subscription' => {'last_logging_reminder_notification' => Time.now.iso8601}
          })
          alerts[:recent_less_active] += 1
        end
      end

      # send out a two and one-month warning when account is 
      # going to be deleted for inactivity (after 12 months of non-use)
      to_be_deleted_ids = User.where(['updated_at < ?', 12.months.ago]).order('updated_at ASC').limit(500).map(&:id)
      non_expired_ids = []
      # if users are on an expired free trial, we can delete them much sooner
      trial_to_be_deleted_ids = []
      User.where(["expires_at < ? AND updated_at < ? AND updated_at != DATE_TRUNC('hour', updated_at)", 1.week.ago, 4.weeks.ago]).order('updated_at ASC').limit(200).select do |u|
        if u.billing_state == :expired_communicator
          trial_to_be_deleted_ids << u.id
          true
        else
          non_expired_ids << u.id
          false
        end
      end

      # Catch-up script if things get out of hand
      # exp_ids = []
      # User.where(["expires_at < ? AND updated_at < ? AND updated_at != DATE_TRUNC('hour', updated_at)", 30.week.ago, 30.weeks.ago]).find_in_batches(batch_size: 25) do |batch|
      #   batch.each do |user|
      #     if user.billing_state == :expired_communicator
      #       if user.settings['subscription'] == {"expiration_source"=>"free_trial"} || (!user.settings['past_purchase_durations'] && !user.settings['last_purchase_plan_id'])
      #         next if user.user_name.match(/^testing/) && user.settings['email'] == 'testing@example.com'
      #         next if user.settings['preferences']['allow_log_reports'] && user.updated_at > 36.months.ago
      #         next if user.settings['preferences']['never_delete']
      #         exp_ids << user.id
      #       else
      #         # puts user.settings['subscription'].to_json
      #       end
      #     end
      #   end
      #   puts exp_ids.length
      # end;

      User.where(id: non_expired_ids).update_all("updated_at = DATE_TRUNC('hour', updated_at)")
      to_be_deleted = User.where(id: (to_be_deleted_ids + trial_to_be_deleted_ids).uniq)
      to_be_deleted.find_in_batches(batch_size: 25) do |batch|
        batch.each do |user|
          if user.user_name.match(/^testing/) && user.settings['email'] == 'testing@example.com'
            user.touch
            next
          end
          # Don't delete communicators marked as never-delete or who allow
          # anonymized reports for tracking
          next if user.settings['preferences']['allow_log_reports'] && user.updated_at > 36.months.ago
          next if user.settings['preferences']['never_delete']
          user.settings['subscription'] ||= {}
          last_warning = Time.parse(user.settings['subscription']['last_deletion_warning']) rescue Time.at(0)
          if last_warning < 3.weeks.ago
            attempts = 1
            if last_warning > 20.weeks.ago
              attempts = (user.settings['subscription']['last_deletion_attempts'] || 0) + 1
            end
            if attempts > 2
              user.schedule_deletion_at = 36.hours.from_now
              user.save(touch: false)
              SubscriptionMailer.deliver_message(:account_deleted, user.global_id)
            else
              SubscriptionMailer.deliver_message(:deletion_warning, user.global_id, attempts)
              alerts[:pending_deletes] += 1
              user.update_setting({
                'subscription' => {
                  'last_deletion_warning' => Time.now.iso8601,
                  'last_deletion_attempts' => attempts
                }
              })
            end
            User.where(id: user.id).update_all(updated_at: 12.months.ago + 3.weeks)
          end
        end
      end
      alerts
    end

    def default_eval_duration
      90
    end

    def purchase_extras(opts)
      user = User.find_by_global_id(opts['user_id'])
      raise "user not found" unless user
      user.settings['subscription'] ||= {}
      extras_purchase_id = "extras:#{opts['purchase_id']}"
      return false if opts['purchase_id'] && (user.settings['subscription']['prior_purchase_ids'] || []).include?(extras_purchase_id)
      if opts['premium_supporters'].to_i > 0
        user.settings['subscription']['purchased_supporters'] ||= 0
        user.settings['subscription']['purchased_supporters'] += opts['premium_supporters']
      end
      if opts['premium_symbols']
        first_enabling = !(user.settings['subscription']['extras'] && user.settings['subscription']['extras']['enabled'])
        if opts['source'] == 'org_added' && user.settings['subscription']['extras'] && user.settings['subscription']['extras']['enabled']
          raise "extras already activated for user"
        end
        user.settings['subscription']['extras'] = (user.settings['subscription']['extras'] || {}).merge({
          'enabled' => true,
          'purchase_id' => opts['purchase_id'],
          'customer_id' => opts['customer_id'],
          'source' => opts['source']
        })
        if opts['source'] == 'org_added' && opts['org_id']
          user.settings['subscription']['extras']['org_id'] = opts['org_id']
        end
        if opts['source'] == 'org_added' && !opts['new_activation']
          first_enabling = false
        end
        user.settings['subscription']['extras']['sources'] ||= []
        user.settings['subscription']['extras']['sources'] << {
          'timestamp' => Time.now.to_i,
          'customer_id' => opts['customer_id'],
          'source' => opts['source']
        }
        if first_enabling
          AuditEvent.create!(:event_type => 'extras_added', :summary => "#{user.user_name} activated extras", :data => {source: opts['source']})
        end
        if first_enabling && opts['notify']
          SubscriptionMailer.schedule_delivery(:extras_purchased, user.global_id)
        end
      end
      if opts['purchase_id']
        user.settings['subscription']['prior_purchase_ids'] ||= []
        user.settings['subscription']['prior_purchase_ids'] << extras_purchase_id
      end
      user.save_with_sync('purchase_extras')
      true
    end

    def deactivate_extras(opts)
      user = User.find_by_global_id(opts['user_id'])
      if user && user.settings['subscription'] && user.settings['subscription']['extras']
        if user.settings['subscription']['extras']['source'] == 'org_added'
          if opts['org_id'] && user.settings['subscription']['extras']['org_id'] == opts['org_id']
            user.settings['subscription']['extras']['enabled'] = false
            user.settings['subscription']['extras']['sources'] ||= []
            user.settings['subscription']['extras']['sources'] << {
              'timestamp' => Time.now.to_i,
              'source' => 'deactivated'
            }
            user.save_with_sync('deactivate_extras')
          else
            raise "deactivating from the wrong org" unless opts['ignore_errors']
          end
        else
          raise "only org-added extras can be deactivated" unless opts['ignore_errors']
        end
      else
        raise "extras not activated" unless opts['ignore_errors']
      end
    end
    
    def subscription_event(args)
      # ping from purchasing system, find the appropriate user and pass it along
      user = User.find_by_path(args['user_id'])
      return false unless user
      res = user.subscription_event(args)
      if args['cancel_others_on_update'] && res
        Purchasing.cancel_other_subscriptions(user, args['subscription_id'])
      end
      res
    end
  end
end