class User < ActiveRecord::Base
  include Processable
  include Permissions
  include Passwords
  include Async
  include GlobalId
  include MetaRecord
  include Supervising
  include SecureSerialize
  include Notifiable
  include Notifier
  include Subscription
  include BoardCaching
  include Renaming
  has_many :log_sessions
  has_many :boards
  has_many :devices
  has_many :user_integrations
  has_one :user_extra
  before_save :generate_defaults
  after_save :track_boards
  after_save :notify_of_changes
#  replicated_model

  has_paper_trail :only => [:settings, :user_name],
                  :if => Proc.new{|u| PaperTrail.request.whodunnit && !PaperTrail.request.whodunnit.match(/^job/) }
              
  secure_serialize :settings
  attr_accessor :permission_scopes

  # cache should be invalidated if:
  # - a supervisor is added or removed
  # super-fast lookups, already have the data
  add_permissions('view_existence', ['*']) { true } # anyone can get basic information
  add_permissions('view_existence', ['none']) { true } # anyone can get basic information
  add_permissions('view_existence', 'view_detailed', 'view_deleted_boards', 'view_word_map', ['*']) {|user| user.id == self.id && !user.valet_mode? }
  add_permissions('view_existence', 'view_detailed', 'model', 'supervise', 'edit', 'edit_boards', 'manage_supervision', 'delete', 'view_deleted_boards', 'link_auth') {|user| user.id == self.id && !user.valet_mode? }
  add_permissions('view_existence', 'view_detailed', 'view_word_map', 'model', ['modeling']) {|user| user.id == self.id && user.valet_mode? }
  add_permissions('view_existence', 'view_detailed', ['*']) { self.settings && self.settings['public'] == true }
  add_permissions('set_goals', ['basic_supervision']) {|user| user.id == self.id && !user.valet_mode? }

  add_permissions('edit', 'manage_supervision', 'view_deleted_boards') {|user| user.edit_permission_for?(self, true) && !user.valet_mode? }
  add_permissions('edit', 'edit_boards', 'manage_supervision', 'view_deleted_boards') {|user| user.edit_permission_for?(self, false) && !user.valet_mode? }
  add_permissions('view_existence', 'view_detailed', 'model') {|user| user.supervisor_for?(self) && !user.valet_mode?}
  add_permissions('view_existence', 'view_detailed', 'model', 'supervise', 'view_deleted_boards', 'set_goals') {|user| user.supervisor_for?(self) && !user.modeling_only_for?(self) && !user.valet_mode? }
  add_permissions('view_detailed', 'model', ['basic_supervision']) {|user| user.supervisor_for?(self) && !user.valet_mode? }
  add_permissions('view_detailed', 'view_deleted_boards', 'model', 'set_goals', ['basic_supervision']) {|user| user.supervisor_for?(self) && !user.modeling_only_for?(self) && !user.valet_mode? }
  add_permissions('view_word_map', ['*']) {|user| user.supervisor_for?(self) && !user.valet_mode? }
  add_permissions('manage_supervision', 'support_actions', 'link_auth') {|user| Organization.manager_for?(user, self) && !user.valet_mode? }
  add_permissions('view_existence', 'view_detailed', 'model', 'supervise', 'view_deleted_boards', 'set_goals', 'link_auth') {|user| Organization.manager_for?(user, self, true) && !user.valet_mode? }
  add_permissions('admin_support_actions', 'support_actions', 'view_deleted_boards') {|user| Organization.admin_manager?(user) && !user.valet_mode? }
  cache_permissions
  
  def self.find_for_login(user_name, org_id=nil, password=nil, allow_modeling=false)
    user_name = user_name.strip
    res = nil
    if user_name.match(/^model@/) && allow_modeling
      user_id = user_name.sub(/^model@/, '').sub(/\./, '_')
      res = self.find_by_global_id(user_id)
      res.assert_valet_mode! if res
    end
    if !user_name.match(/@/)
      res ||= self.find_by(:user_name => user_name)
      res ||= self.find_by(:user_name => user_name.downcase)
      res ||= self.find_by(:user_name => User.clean_path(user_name.downcase))
    end
    if !res
      emails = self.find_by_email(user_name)
      emails = self.find_by_email(user_name.downcase) if emails.length == 0
      if emails.length > 1 && password
        emails = emails.select{|u| u.valid_password?(password)}
        emails = [] if emails.length > 1
      end
      res = emails[0] if emails.length > 0
    end
    if org_id
      if res.settings['authored_organization_id'] == org_id
      else
        # try looking up org and see if the user has been added there
        # NOTE: someday if you want to scope logins to domain, this is how
        # res = nil
      end
    end
    res
  end
  
  def named_email
    "#{self.settings['name']} <#{self.settings['email']}>"
  end

  def external_email_allowed?
    self.settings ||= {}
    # Org-managed users have protected email addresses
    return !self.settings['authored_organization_id'] && !Organization.managed?(self)
  end
  
  def prior_named_email
    email = self.settings['old_emails'][-1]
    "#{self.settings['name']} <#{email}>"
  end
  
  def registration_type
    res = (self.settings['preferences'] || {})['registration_type']
    res = 'unspecified' if !res || res.length == 0
    res
  end
  
  def supporter_registration?
    !['unspecified', 'communicator'].include?(self.registration_type)
  end
  
  def log_session_duration
    (self.settings['preferences'] && self.settings['preferences']['log_session_duration']) || User.default_log_session_duration
  end
    
  def self.default_log_session_duration
    30.minutes.to_i
  end
  
  def enable_feature(feature)
    self.settings ||= {}
    self.settings['feature_flags'] ||= {}
    self.settings['feature_flags'][feature.to_s] = true
    self.save
  end
  
  def can_access_library?(library)
    false
  end
  
  def disable_feature(feature)
    self.settings['feature_flags'].delete(feature.to_s) if self.settings && self.settings['feature_flags']
    self.save
  end
  
  def default_premium_voices
    User.default_premium_voices(self.full_premium?(true), [:trialing_communicator].include?(self.billing_state), self.eval_account?)
  end
  
  def self.default_premium_voices(full_premium=true, trial_period=false, eval_account=false)
    if full_premium
      if eval_account
        {
          'claimed' => [],
          'allowed' => 1
        }
      else
        {
          'claimed' => [],
          'allowed' => 2
        }
      end
    elsif trial_period
      {
        'claimed' => [],
        'allowed' => 1
      }
    else
      {
        'claimed' => [],
        'allowed' => 0
      }
    end
  end
  
  def allow_additional_premium_voice!
    self.settings ||= {}
    self.settings['premium_voices'] ||= {}
    self.settings['premium_voices']['claimed'] ||= []
    self.settings['premium_voices']['allowed'] ||= 0
    self.settings['premium_voices']['allowed'] += 1
    self.settings['premium_voices']['extra'] ||= 0
    self.settings['premium_voices']['extra'] += 1
    self.save
  end

  def audit_protected_sources
    found_sources = []
    # Check home board
    # Check any user-authored boards
    if self.settings['preferences']['home_board']
      board_ids = []
      b = Board.find_by_path(self.settings['preferences']['home_board']['id'])
      if b
        board_ids << b.global_id
        board_ids += b.settings['downstream_board_ids'] || []
        Board.find_batches_by_global_id(board_ids) do |brd|
          brd.known_button_images.each do |bi|
            if bi.settings && bi.settings['protected_source']
              if !(self.settings['activated_sources'] || []).include?(bi.settings['protected_source'])
                found_sources << bi.settings['protected_source']
                found_sources.uniq!
              end
            end
          end
        end
      end
    end
    self.boards.find_in_batches(batch_size: 25) do |batch|
      batch.each do |brd|
        brd.known_button_images.each do |bi|
          if bi.settings && bi.settings['protected_source']
            if !(self.settings['activated_sources'] || []).include?(bi.settings['protected_source'])
              found_sources << bi.settings['protected_source']
              found_sources.uniq!
            end
          end
        end
      end
    end
    found_sources.uniq.each do |source|
      self.track_protected_source(source)
    end
  end

  def track_protected_source(source_id)
    self.using(:master).reload
    self.settings['activated_sources'] ||= []
    # The first time a user leverages a third-party symbol library by 
    # saving a board with an image, log it as activated (unless it happens)
    # during the free trial, in which case it needs to be tracked at
    # purchase.
    if !self.settings['activated_sources'].include?(source_id) && !self.subscription_hash['grace_trial_period'] && !self.subscription_hash['grace_period']
      log_activation = true
      if source_id == 'lessonpix'
        template = UserIntegration.find_by(template: true, integration_key: 'lessonpix')
        ui = template && UserIntegration.find_by(user: self, template_integration: template)
        if ui && ui.settings && ui.settings['user_settings'] && ui.settings['user_settings']['username']
          log_activation = false
        end
      elsif source_id == 'giphy_asl'
        log_activation = false
      end
      self.settings['activated_sources'] << source_id
      self.save
      if log_activation
        ae = AuditEvent.find_by(user_key: self.global_id, record_id: source_id)
        ae ||= AuditEvent.create!(:user_key => self.global_id, :record_id => source_id, :event_type => 'source_activated', :summary => "#{self.user_name} activated #{source_id}", :data => {source: source_id})
      end
    end
  end

  def access_methods(device=nil)
    if self.settings['external_device']
      return [self.settings['external_device']['access_method'] || 'touch']
    end
    devices = ((self.settings || {})['preferences'] || {})['devices']
    types = {}
    (devices || {}).each do |key, device_prefs|
      if !device || device.device_key == key
        method = 'touch'
        if device_prefs['scanning']
          if device_prefs['scan_mode'] == 'axes'
            method = 'axis_scanning'
          else
            method = 'scanning'
          end
        elsif device_prefs['dwell']
          if device_prefs['dwell_type'] == 'arrow_dwell'
            method = 'arrow_dwell'
          elsif device_prefs['dwell_type'] == 'mouse_dwell'
            method = 'arrow_dwell'
          elsif device_prefs['dwell_type'] == 'eyegaze'
            method = 'gaze'
          elsif device_prefs['dwell_type'] == 'head'
            method = 'head'
          else
            method = 'dwell'
          end
        end
        types[method] = (types[method] || 0) + 1
      end
    end
    types.delete('touch') if types.keys.length > 1
    types.to_a.sort_by{|a, b| b }.reverse.map(&:first)
  end
  
  def add_premium_voice(voice_id, system_name)
    # Limit the number of premium_voices users can download
    voices = {}.merge(self.settings['premium_voices'] || {})
    voices['claimed'] ||= self.default_premium_voices['claimed']
    voices['allowed'] = [voices['allowed'] || 0, self.default_premium_voices['allowed']].max
    
    claimed_by_supervisee = self.supervisees.detect do |sup|
      ((sup.settings['premium_voices'] || {})['claimed'] || []).include?(voice_id)
    end
    is_admin = Organization.admin_manager?(self)
    pre_claimed = voices['claimed']
    if is_admin
      voices['allowed'] = [voices['allowed'] || 0, voices['claimed'].length + 1].max
      voices['claimed'] = voices['claimed'] | [voice_id]
      voices['allowed'] = [voices['allowed'] || 0, voices['claimed'].length + 1].max
    elsif claimed_by_supervisee
      voices['sup_claimed'] ||= []
      voices['sup_claimed'] = voices['sup_claimed'] | [voice_id]
    else
      voices['claimed'] = voices['claimed'] | [voice_id]
    end

    new_voice = !is_admin && voices['claimed'].include?(voice_id) && !pre_claimed.include?(voice_id)
    if voices['claimed'].length > voices['allowed']
      return false
    else
      if new_voice
        if [:trialing_communicator, :trialing_supervisor].include?(self.billing_state)
          voices['trial_voices'] = (voices['trial_voices'] || []).select{|t| t['i'] != voice_id }
          voices['trial_voices'] << {s: system_name, i: voice_id}
        else
          # Log voice claims for payment, unless an admin user or supervisor
          self.track_voice_added(voice_id, system_name)
        end
      end
      self.settings['premium_voices'] = voices
      self.save
      return true
    end
  end

  def refresh_premium_voices
    if !self.any_premium_or_grace_period?(true)
      if !(self.settings['premium_voices'] || {})['expired_state']
        self.settings['premium_voices'] ||= {}
        self.settings['premium_voices']['allowed'] = self.settings['premium_voices']['extra'] || 0
        self.settings['premium_voices']['claimed'] = (self.settings['premium_voices']['claimed'] || [])[0, self.settings['premium_voices']['allowed']]
        self.settings['premium_voices']['expired_state'] = true
        self.save
      end
    end
    self.settings['premium_voices']
  end
  
  def registration_code
    self.settings ||= {}
    if !self.settings['registration_code']
      self.settings['registration_code'] = GoSecure.nonce('reg_code')
      self.save
    end
    self.settings['registration_code']
  end
  
  def anonymized_identifier(str=nil)
    str ||= ""
    self.settings ||= {}
    if !self.settings['anonymized_identifier']
      self.settings['anonymized_identifier'] = GoSecure.nonce('user_pseudonymization')
      self.save
    end
    GoSecure.lite_hmac("#{self.global_id}:#{self.created_at.iso8601}:#{str}", self.settings['anonymized_identifier'], 1)
  end

  def possible_admin?
    !!(self.settings && self.settings['possible_admin'])
  end
  
  def self.preference_defaults
    {
      'device' => {
        'voice' => {'pitch' => 1.0, 'volume' => 1.0},
        'button_spacing' => 'small',
        'button_border' => 'small',
        'button_text' => 'medium',
        'button_text_position' => 'top',
        'utterance_text_only' => false,
        'vocalization_height' => 'small',
        'wakelock' => true
      },
      'any_user' => {
        'activation_location' => 'end',
        'auto_home_return' => true,
        'vocalize_buttons' => true,
        'external_links' => 'confirm_custom',
        'clear_on_vocalize' => true,
        'sharing' => true,
        'board_jump_delay' => 500,
        'battery_sounds' => true,
        'default_sidebar_boards' => default_sidebar_boards,
        'blank_status' => false,
        'preferred_symbols' => 'original',
        'word_suggestion_images' => true,
        'hidden_buttons' => 'grid',
        'symbol_background' => 'clear',
        'utterance_interruptions' => true,
        'click_buttons' => true,
        'auto_capitalize' => true,
        'prefer_native_keyboard' => false
      },
      'authenticated_user' => {
        'long_press_edit' => false,
        'require_speak_mode_pin' => false,
        'logging' => false,
        'geo_logging' => false,
        'role' => 'communicator',
        'auto_open_speak_mode' => true,
        'share_notifications' => 'email',
        'cookies' => true
      }
    }
  end

  def generate_defaults
    self.settings ||= {}
    self.settings['name'] ||= "No name"
    self.settings['preferences'] ||= {}
    self.settings['preferences']['progress'] ||= {}
    if self.settings['preferences']['home_board']
      self.settings['preferences']['progress']['home_board_set'] = true
      self.settings['all_home_boards'] ||= []
      ref = self.settings['preferences']['home_board'].slice('key', 'id', 'locale')
      if self.settings['all_home_boards'][-1] != ref
        self.settings['all_home_boards'] << ref
        self.settings['home_board_changed'] = true
        self.settings['all_home_boards'] = self.settings['all_home_boards'].uniq
      end
    end
    self.settings['edit_key'] = Time.now.to_f.to_s + "-" + rand(9999).to_s
    self.settings['preferences']['devices'] ||= {}
    self.settings['preferences']['devices']['default'] ||= {}
    self.settings['preferences']['devices']['default']['name'] ||= "Web browser for Desktop"
    self.settings['preferences']['devices'].each do |key, hash|
      self.settings['preferences']['devices'][key]['voice']['voice_uris'].uniq! if self.settings['preferences']['devices'][key]['voice'] && self.settings['preferences']['devices'][key]['voice']['voice_uris']
      self.settings['preferences']['devices'][key]['alternate_voice']['voice_uris'].uniq! if self.settings['preferences']['devices'][key]['alternate_voice'] && self.settings['preferences']['devices'][key]['alternate_voice']['voice_uris']
      User.preference_defaults['device'].each do |attr, val|
        self.settings['preferences']['devices'][key][attr] = val if self.settings['preferences']['devices'][key][attr] == nil
      end
    end
    if self.settings['preferences']['cookies'] == false
      self.settings['preferences']['protected_user'] = true
    end
    self.settings['preferences']['disable_quick_sidebar'] = false if self.settings['preferences']['quick_sidebar']
    if !FeatureFlags.user_created_after?(self, 'word_suggestion_images')
      self.settings['preferences']['word_suggestion_images'] = false if self.settings['preferences']['word_suggestion_images'] == nil
    end
    if !FeatureFlags.user_created_after?(self, 'hidden_buttons')
      self.settings['preferences']['hidden_buttons'] = 'hide' if self.settings['preferences']['hidden_buttons'] == nil
    end
    if FeatureFlags.user_created_after?(self, 'skin_tones')
      self.settings['preferences']['skin'] = "mix#{rand(999)}" if self.settings['preferences']['skin'] == nil
    end
    if !FeatureFlags.user_created_after?(self, 'symbol_background')
      self.settings['preferences']['symbol_background'] = 'white' if self.settings['preferences']['symbol_background'] == nil
    end
    if !FeatureFlags.user_created_after?(self, 'battery_sounds')
      self.settings['preferences']['battery_sounds'] = true if self.settings['preferences']['battery_sounds'] == nil
    end
    if FeatureFlags.user_created_after?(self, 'utterance_core_access')
      self.settings['preferences']['utterance_core_access'] = true if self.settings['preferences']['utterance_core_access'] == nil
    end
    self.settings['preferences']['utterance_core_access'] = true if self.settings['preferences']['utterance_core_access'] == nil && self.settings['preferences']['logging']
    self.settings['preferences']['utterance_core_access'] ||= false
    if !FeatureFlags.user_created_after?(self, 'auto_capitalize')
      self.settings['preferences']['auto_capitalize'] = true if self.settings['preferences']['auto_capitalize'] == nil
      self.settings['preferences']['devices'].each do |key, hash|
        self.settings['preferences']['devices'][key]['utterance_text_only'] = true if self.settings['preferences']['devices'][key]['utterance_text_only'] == nil
      end
    end
    self.settings['preferences']['auto_capitalize'] ||= false
    if FeatureFlags.user_created_after?(self, 'new_index')
      self.settings['preferences']['new_index'] = true if self.settings['preferences']['new_index'] == nil
    end
    if FeatureFlags.user_created_after?(self, 'click_buttons')
      self.settings['preferences']['click_buttons'] = true if self.settings['preferences']['click_buttons'] == nil
    end
    if FeatureFlags.user_created_after?(self, 'recent_cleared_phrases')
      self.settings['preferences']['recent_cleared_phrases'] = true if self.settings['preferences']['recent_cleared_phrases'] == nil
    end
    self.settings['preferences']['click_buttons'] ||= false
    if FeatureFlags.user_created_after?(self, 'utterance_interruptions')
      self.settings['preferences']['utterance_interruptions'] = true if self.settings['preferences']['utterance_interruptions'] == nil
    end
    self.settings['preferences']['utterance_interruptions'] ||= false
    if self.settings['preferences']['confirm_external_links']
      self.settings['preferences']['external_links'] = 'confirm_custom'
      self.settings['preferences'].delete('confirm_external_links')
    end
    User.preference_defaults['any_user'].each do |attr, val|
      self.settings['preferences'][attr] = val if self.settings['preferences'][attr] == nil
    end
    User.preference_defaults['authenticated_user'].each do |attr, val|
      self.settings['preferences'][attr] = val if self.settings['preferences'][attr] == nil
    end
    if self.settings['preferences']['role'] != 'communicator'
      self.settings['preferences'].delete('auto_open_speak_mode')
    end
    if self.settings['preferences']['notification_frequency']
      self.next_notification_at ||= next_notification_schedule
    end
    # Extend all trials until July 31, 2020
    if (!self.expires_at && !self.id) || (self.grace_period? && self.id)
      extension = Rails.env.test? ? Date.today : Date.parse('2020-07-31')
      old_exp = self.expires_at
      self.expires_at = [self.expires_at || Date.today + 60, extension].max
      self.settings['subscription'] ||= {}
      self.settings['subscription']['expiration_source'] = (self.id ? 'grace_period' : 'free_trial') if self.expires_at != old_exp
    end
    return false if self.user_name == ""
    self.user_name = nil if self.user_name.blank?
    self.user_name ||= self.generate_user_name(self.settings['name'])
    self.email_hash = User.generate_email_hash(self.settings['email'])
    
    self.assert_eval_settings
    if self.full_premium? || self.possibly_full_premium == nil
      self.possibly_full_premium = true if self.full_premium?
      self.possibly_full_premium ||= rand(20) == 1
    end
    if !self.id
      self.settings['home_board_changed'] = true
      @do_track_boards = true 
    end
    UserLink.invalidate_cache_for(self)
    true
  end

  def edit_key
    self.settings['edit_key']
  end

  def save_with_sync(reason)
    self.sync_stamp = Time.now
    self.settings ||= {}
    self.settings['sync_stamp_reason'] = reason
    self.save_sync_supervisors
    self.save
  end

  def save_sync_supervisors(do_update=false)
    if do_update
      self.supervisors.each do |sup|
        sup.save_with_sync('supervisee update')
      end
    else
      ra_cnt = RemoteAction.where(path: "#{self.global_id}", action: 'save_sync_supervisors').count
      RemoteAction.create(path: "#{self.global_id}", act_at: 15.minutes.from_now, action: 'save_sync_supervisors') if ra_cnt == 0
    end
  end
  
  def self.find_by_email(email, lookup=User)
    hash = User.generate_email_hash(email)
    lookup.where(:email_hash => hash).order('user_name')
  end
  
  def self.generate_email_hash(email)
    Digest::MD5.hexdigest((email || "none").to_s.strip.downcase)
  end
  
  def generated_avatar_url(override_url=nil)
    bucket = ENV['STATIC_S3_BUCKET'] || "coughdrop"
    id = self.id || 0
    fallback = "https://#{bucket}.s3.amazonaws.com/avatars/avatar-#{id % 10}.png"
    url = self.settings && self.settings['avatar_url']
    url = override_url if override_url
    if url == 'fallback'
      fallback
    elsif url && url != 'default'
      # NOTE: somewhere we should enforce that it's coming from a reliable location, or provide a fallback
      url
    else
      email_md5 = Digest::MD5.hexdigest(self.settings['email'] || "none")
      "https://www.gravatar.com/avatar/#{email_md5}?s=100&d=#{CGI.escape(fallback)}"
    end
  end
  
  def prior_avatar_urls
    res = self.settings && self.settings['prior_avatar_urls']
    current = generated_avatar_url
    default = generated_avatar_url('default')
    if (res && res.length > 0) || current != default
      res = res || []
      res.push(default)
      res.uniq!
    end
    res
  end
  
  # frd == "For Reals, Dude" obviously. It's a thing, I guess you just didn't know about it.
  # TODO: add "frd" to urban dictionary
  def track_boards(frd=false, ts=nil)
    if !@do_track_boards && !frd
      return true
    end
    @do_track_boards = false
    if frd != true
      if self.settings && (self.settings['home_board_changed'] || self.settings['sidebar_changed'])
        self.schedule_once_for(RedisInit.any_queue_pressure? ? :whenever : :slow, :track_boards, true, ts || Time.now.to_i)
      end
      return true
    end
    if ts && self.settings['tracked_boards_at'] && ts < self.settings['tracked_boards_at']
      # Prevent multiple tracks for the same user
      return false
    end
    if ts && frd
      self.settings['tracked_boards_at'] = Time.now.to_i
      self.save
    end
    
    previous_connections = UserBoardConnection.where(:user_id => self.id)
    orphan_board_ids = previous_connections.map(&:board_id)
    linked_boards = []
    board_ids_to_recalculate = []
    if self.settings['preferences'] && self.settings['preferences']['home_board'] && self.settings['preferences']['home_board']['id']
      brd = Board.find_by_path(self.settings['preferences']['home_board']['id'])
      linked_boards << {
        board: brd,
        locale: self.settings['preferences']['home_board']['locale'] || brd.settings['locale'] || 'en',
        changed: self.settings['home_board_changed'],
        home: true
      } if brd
    end
    if self.settings['preferences'] && self.settings['preferences']['sidebar_boards']
      self.settings['preferences']['sidebar_boards'].each do |brd|
        board_record = Board.find_by_path(brd['key'])
        linked_boards << {
          board: board_record,
          locale: brd['locale'] || board_record.settings['locale'] || 'en',
          changed: self.settings['sidebar_changed'],
          home: false
        } if brd['key']
      end
    end
    Board.lump_triggers
    board_added = false
    linked_boards.each do |hash|
      board = hash[:board]
      if board
        orphan_board_ids -= [board.id]
        # TODO: sharding
        ubc = UserBoardConnection.find_or_create_by(:board_id => board.id, :user_id => self.id, :home => hash[:home]) do |rec|
          # Remember: only called on create, not find
          rec.locale = hash[:locale] || rec.locale
          board_added = true
          UserBoardConnection.where(board_id: rec.id).update_all(parent_board_id: rec.parent_board_id)
        end
        if ubc.locale != hash[:locale] && hash[:locale]
          UserBoardConnection.where(id: ubc.id).update_all(locale: hash[:locale])
        end
        board.instance_variable_set('@skip_update_available_boards', true)
        # NOTE: I *think* this is here because board permissions may change for
        # supervisors/supervisees when a user's home board changes
        board.track_downstream_boards!(nil, nil, Board.last_scheduled_stamp || Time.now.to_i)
        Rails.logger.info("checking downstream boards for #{self.global_id}, #{board.global_id}")
        
        Board.select('id, parent_board_id').find_batches_by_global_id(board.settings['downstream_board_ids'] || [], batch_size: 50) do |downstream_board|
          if downstream_board
            orphan_board_ids -= [downstream_board.id]
            downstream_board_added = false
            ubc = UserBoardConnection.find_or_create_by(:board_id => downstream_board.id, :user_id => self.id) do |rec|
              # Remember: only called on create, not find
              rec.locale = hash[:locale] || rec.locale
              board_added = true
              downstream_board_added = true
              UserBoardConnection.where(board_id: rec.id).update_all(parent_board_id: rec.parent_board_id)
            end
            if ubc.locale != hash[:locale] && hash[:locale]
              UserBoardConnection.where(id: ubc.id).update_all(locale: hash[:locale])
            end
            # When a user updated their home board/sidebar, all linked boards will have updated
            # tallies for popularity, home_popularity, etc.
            board_ids_to_recalculate << downstream_board.global_id if hash[:changed]
          end
        end
        Rails.logger.info("done checking downstream boards for #{self.global_id}, #{board.global_id}")
      end
    end
    Rails.logger.info("processing lumped triggers")
    Board.process_lumped_triggers
    Rails.logger.info("done processing lumped triggers")
    
    if board_added || orphan_board_ids.length > 0
      # TODO: sharding
      User.where(:id => self.id).update_all(:updated_at => Time.now, :sync_stamp => Time.now, :boards_updated_at => Time.now)
      Board.schedule(:regenerate_shared_board_ids, [self.global_id])
    end
    
    UserBoardConnection.where(:user_id => self.id, :board_id => orphan_board_ids).delete_all
    # TODO: sharding
    board_ids_to_recalculate += Board.where(:id => orphan_board_ids).select('id').map(&:global_id)
    if self.settings['home_board_changed'] || self.settings['sidebar_changed']
      self.settings.delete('home_board_changed')
      self.settings.delete('sidebar_changed')
      @do_track_boards = false
      self.save
    end
    # to regenerates stats?
    if !RedisInit.any_queue_pressure?
      board_ids_to_recalculate.uniq.each_slice(100) do |ids|
        if ids.length > 0
          stash = JobStash.create(data: ids)
          Board.schedule_for(:slow, :refresh_stats, {'stash' => stash.global_id}, Time.now.to_i) 
        end
      end
    end
    true
  end

  def remember_starred_board!(board_id)
    board = Board.find_by_path(board_id)
    if board
      star = board.starred_by?(self)
      self.settings['starred_board_ids'] ||= []
      if star
        self.settings['starred_board_ids'] << board.shallow_id if board
        self.settings['starred_board_ids'].uniq!
      else
        self.settings['starred_board_ids'] = self.settings['starred_board_ids'] - [board.shallow_id]
      end
      self.settings['starred_boards'] = self.settings['starred_board_ids'].length
      self.save_with_sync('star_list_changed')
    end
  end

  def starred_board_refs
    refs = []
    user = self
    brds = {}
    Board.find_all_by_global_id((user.settings['starred_board_ids'] || [])[0, 25]).each do |b|
      brds[b.global_id] = b
      brds[b.global_id(true)] = b
    end
    (user.settings['starred_board_ids'] || []).each do |id|
      brd = brds[id]
      if brd
        id = brd.global_id
        key = brd.key
        if FeatureFlags.feature_enabled_for?('shallow_clones', user)
          id = "#{brd.global_id(true)}-#{user.global_id}"
          key = "#{user.user_name}/my:#{brd.key.sub(/\//, ':')}"
        end
        refs << {'id' => id, 'key' => key, 'image_url' => brd.settings['image_url'], 'name' => brd.settings['name']}
      end
    end
    if refs.length < 8
      home_board_id = (user.settings['preferences']['home_board'] || {})['id']
      ::Board.find_suggested(user.settings['preferences']['locale'] || 'en', 5).each do |board|
        if home_board_id == board.global_id
        elsif !brds[board.global_id] && refs.length < 12
          id = board.global_id
          key = board.key
          if FeatureFlags.feature_enabled_for?('shallow_clones', user)
            id = "#{board.global_id(true)}-#{user.global_id}"
            key = "#{user.user_name}/my:#{board.key.sub(/\//, ':')}"
          end
          if board.settings['board_style']
            refs << {
              'id' => id,
              'key' => key,
              'name' => board.settings['name'],
              'suggested' => true,
              'style' => board.settings['board_style'],
              'image_url' => board.settings['image_url']
            }
          else
            refs << {
              'id' => id,
              'key' => key,
              'name' => board.settings['name'],
              'suggested' => true,
              'image_url' => board.settings['image_url']
            }
          end
        end
      end
    end
    refs
  end
  
  def board_set_ids(opts=nil)
    opts ||= {}
    include_supervisees = opts['include_supervisees'] || opts[:include_supervisees] || false
    include_starred = opts['include_starred'] || opts[:include_starred] || false
    root_board_ids = []
    board_ids = []
    if self.settings && include_starred
      board_ids += self.settings['starred_board_ids'] || []
      root_board_ids += self.settings['starred_board_ids'] || []
    end
    if self.settings && self.settings['preferences'] && self.settings['preferences']['home_board']
      root_board_ids += [self.settings['preferences']['home_board']['id']] 
    end
    if include_supervisees
      if self.supervised_user_ids.length < 5
        self.supervisees.each do |u|
          if u.settings && u.settings['preferences'] && u.settings['preferences']['home_board']
            root_board_ids  += [u.settings['preferences']['home_board']['id']]
          end
        end
      end
    end

    board_ids += root_board_ids
    root_boards = Board.find_all_by_global_id(root_board_ids)
    root_boards.each do |board|
      board_ids += board.downstream_board_ids || []
    end
    
    board_ids.uniq
  end
  
  PREFERENCE_PARAMS = ['sidebar', 'auto_home_return', 'vocalize_buttons', 
      'sharing', 'button_spacing', 'quick_sidebar', 'disable_quick_sidebar', 
      'lock_quick_sidebar', 'clear_on_vocalize', 'logging', 'geo_logging', 
      'require_speak_mode_pin', 'speak_mode_pin', 'activation_minimum',
      'activation_location', 'activation_cutoff', 'activation_on_start', 
      'confirm_external_links', 'external_links', 'long_press_edit', 'scanning', 'scanning_interval',
      'scanning_mode', 'scanning_select_keycode', 'scanning_next_keycode', 
      'scanning_prev_keycode', 'scanning_cancel_keycode',
      'scanning_select_on_any_event', 'vocalize_linked_buttons', 'sidebar_boards',
      'silence_spelling_buttons', 'stretch_buttons', 'registration_type',
      'board_background', 'vocalization_height', 'role', 'auto_open_speak_mode',
      'canvas_render', 'blank_status', 'share_notifications', 'notification_frequency',
      'skip_supervisee_sync', 'sync_refresh_interval', 'multi_touch_modeling',
      'goal_notifications', 'word_suggestion_images', 'hidden_buttons',
      'speak_on_speak_mode', 'ever_synced', 'folder_icons', 'allow_log_reports', 'allow_log_publishing', 
      'symbol_background', 'disable_button_help', 'click_buttons', 'prevent_hide_buttons',
      'new_index', 'debounce', 'cookies', 'preferred_symbols', 'tag_ids', 'vibrate_buttons',
      'highlighted_buttons', 'never_delete', 'dim_header', 'inflections_overlay',
      'highlight_popup_text', 'phrase_categories', 'high_contrast', 'swipe_pages',
      'hide_pin_hint', 'battery_sounds', 'auto_inflections', 'private_logging',
      'remote_modeling', 'remote_modeling_auto_follow', 'remote_modeling_auto_accept',
      'locale', 'logging_cutoff', 'logging_permissions', 'logging_code',
      'substitutions', 'substitute_contractions', 'auto_capitalize', 'dim_level',
      'prevent_button_interruptions', 'utterance_interruptions', 'prevent_utterance_repeat',
      'recent_cleared_phrases', 'clear_vocalization_history', 'clear_vocalization_history_count', 
      'clear_vocalization_history_minutes', 'speak_mode_edit', 'skin', 'hide_gif',
      'extra_colors', 'sync_starred_boards'
    ]
  CONFIRMATION_PREFERENCE_PARAMS = ['logging', 'private_logging', 'geo_logging', 'allow_log_reports', 
      'allow_log_publishing', 'cookies', 'never_delete', 'logging_cutoff', 'logging_permissions', 'logging_code']
  RESEARCH_PREFERENCE_PARAMS = ['research_primary_use', 'research_age', 'research_experience_level']
  PROGRESS_PARAMS = ['setup_done', 'intro_watched', 'profile_edited', 'preferences_edited', 
      'home_board_set', 'app_added', 'skipped_subscribe_modal', 'speak_mode_intro_done',
      'modeling_intro_done', 'modeling_ideas_viewed', 'modeling_ideas_target_words_reviewed',
      'board_intros']
  def process_params(params, non_user_params)
    self.settings ||= {}
    ['name', 'description', 'details_url', 'location', 'cell_phone'].each do |arg|
      self.settings[arg] = process_string(params[arg]) if params[arg]
    end
    if params['terms_agree']
      self.settings['terms_agreed'] = Time.now.to_i
    end
    if params['avatar_url'] && (params['avatar_url'].match(/^http/) || params['avatar_url'] == 'fallback')
      if self.settings['avatar_url'] && self.settings['avatar_url'] != 'fallback'
        self.settings['prior_avatar_urls'] ||= []
        self.settings['prior_avatar_urls'] << self.settings['avatar_url']
        self.settings['prior_avatar_urls'].uniq!
      end
      self.settings['avatar_url'] = params['avatar_url']
    end
    if params['external_device']
      self.settings['external_device'] = params['external_device']
    elsif params.has_key?('external_device')
      self.settings.delete('external_device')
    end
    new_email = params['email'] && params['email'].gsub(/\s/, '')
    if new_email && new_email != self.settings['email']
      if self.settings['email']
        self.settings['old_emails'] ||= []
        self.settings['old_emails'] << self.settings['email']
        @email_changed = true
      end
      if (!self.id || @email_changed) && Setting.blocked_email?(new_email)
        add_processing_error("blocked email address")
        return false
      end
      self.settings['email'] = process_string(new_email)
    end
    self.settings['referrer'] ||= params['referrer'] if params['referrer']
    self.settings['ad_referrer'] ||= params['ad_referrer'] if params['ad_referrer']
    if params['authored_organization_id'] && !self.id
      org = Organization.find_by_global_id(params['authored_organization_id'])
      if org && non_user_params[:author] && org.allows?(non_user_params[:author], 'edit')
        self.settings['authored_organization_id'] = org.global_id
        self.settings['pending'] = false
      end
    end
    if params['last_message_read']
      if params['last_message_read'] >= (self.settings['last_message_read'] || 0)
        self.settings['unread_messages'] = 0
        self.settings['last_message_read'] = params['last_message_read']
      end
    end
    if params['last_alert_access']
      if params['last_alert_access'] >= (self.settings['last_alert_access'] || 0)
        self.settings['unread_alerts'] = 0
        self.settings['last_alert_access'] = params['last_alert_access']
      end
    end
    if params['focus_words'] && self.id
      extra = UserExtra.find_or_create_by(user: self)
      extra.process_focus_words(params['focus_words'])
    end
    if params['read_notifications']
      self.settings['user_notifications_cutoff'] = Time.now.utc.iso8601
    end
    self.settings['preferences'] ||= {}
    if !non_user_params['updater'] || non_user_params['updater'].global_id != self.global_id
      if params['preferences']
        params['preferences'].delete('private_logging') 
        params['preferences'].delete('logging_cutoff') 
        params['preferences'].delete('logging_preferences') 
        params['preferences'].delete('logging_code') 
      end
      params.delete('valet_login')
    end
    if params['valet_login']
      self.set_valet_password(params['valet_password'])
      self.settings['valet_long_term'] = process_boolean(params['valet_long_term']) if params['valet_long_term'] != nil
      self.settings['valet_prevent_disable'] = process_boolean(params['valet_prevent_disable']) if params['valet_prevent_disable'] != nil
    elsif params['valet_login'] == false
      self.set_valet_password(false)
    end
    if params['preferences']
      CONFIRMATION_PREFERENCE_PARAMS.each do |key|
        if params['preferences'][key] != self.settings['preferences'][key]
          self.settings['confirmation_log'] ||= []
          self.settings['confirmation_log'] << {
            'updater' => (non_user_params['updater'] ? non_user_params['updater'].global_id : PaperTrail.request.whodunnit),
            'setting' => key,
            'timestamp' => Time.now.utc.iso8601
          }
          if self.id && key == 'cookies' && params['preferences'] && params['preferences']['cookies'] == false && self.settings['preferences']['cookies'] == true
            @opt_out = 'disabled'
          end
        end
      end
      if params['preferences']['extend_eval']
        self.extend_eval(params['preferences']['extend_eval'], non_user_params[:author])
      end
      if params['preferences']['eval']
        self.settings['eval_reset'] ||= {}
        self.settings['eval_reset']['email'] = params['preferences']['eval']['email']
        self.settings['eval_reset']['home_board']  = params['preferences']['eval']['home_board']
        self.settings['eval_reset']['password'] = GoSecure.generate_password(params['preferences']['eval']['password']) if params['preferences']['eval']['password']
        self.settings['eval_reset']['duration'] = params['preferences']['eval']['duration'].to_i
        self.settings['eval_reset']['duration'] = nil if self.settings['eval_reset']['duration'] == 0
      end
    end
    inflections_were_set = self.settings['preferences']['activation_location'] == 'swipe' || self.settings['preferences']['inflections_overlay']
    params['preferences'].delete('logging_code') if params['preferences'] && params['preferences'] == ''
    PREFERENCE_PARAMS.each do |attr|
      self.settings['preferences'][attr] = params['preferences'][attr] if params['preferences'] && params['preferences'][attr] != nil
    end
    if params['preferences']
      self.settings['preferences']['clear_vocalization_history'] = process_boolean(params['preferences']['clear_vocalization_history']) if params['preferences'] && params['preferences']['clear_vocalization_history'] != nil
      if self.settings['preferences']['clear_vocalization_history']
        self.settings['preferences']['clear_vocalization_history_minutes'] = params['preferences']['clear_vocalization_history_minutes'].to_i if params['preferences']['clear_vocalization_history_minutes']
        self.settings['preferences']['clear_vocalization_history_count'] = params['preferences']['clear_vocalization_history_count'].to_i if params['preferences']['clear_vocalization_history_count']
      end

      research_prefs = {}
      RESEARCH_PREFERENCE_PARAMS.each do |key|
        if !params['preferences'][key].blank?
          research_prefs[key.sub(/^research_/, '')] = params['preferences'][key]
          params['preferences'].delete(key)
        end
      end
      if research_prefs.keys.length > 0 && self.global_id && self.settings['preferences']['allow_log_reports'] && self.communicator_role?
        stash = JobStash.create(data: {'user_id' => self.global_id, 'details' => research_prefs})
        Webhook.schedule(:update_external_prefs, stash.global_id)
      end
    end

    if params['preferences'] && (params['preferences']['logging_code'] == false || params['preferences']['logging_code'] == 'false')
      self.settings['preferences'].delete('logging_code')
    end
    if self.settings['preferences']['logging_cutoff'].is_a?(String)
      if self.settings['preferences']['logging_cutoff'] == 'none' || self.settings['preferences']['logging_cutoff'] == 'false'
        self.settings['preferences'].delete('logging_cutoff')
      else
        self.settings['preferences']['logging_cutoff'] = self.settings['preferences']['logging_cutoff'].to_i
      end
    end
    if self.settings['preferences']['inflections_overlay']
      self.settings['preferences'].delete('long_press_edit')
    end
    if self.id && (self.settings['preferences']['activation_location'] == 'swipe' || self.settings['preferences']['inflections_overlay']) && !inflections_were_set
      self.schedule(:update_home_board_inflections)
    end
    if self.settings['preferences']['external_links']
      self.settings['preferences'].delete('confirm_external_links')
    end
    if params['offline_actions']
      params['offline_actions'].each do |action|
        if action['action'] == 'add_vocalization'
          self.settings['vocalizations'] ||= []
          action['id'] = nil if self.settings['vocalizations'].find{|v| v['id'] == action['id'] }
          cat = action['category'] || 'default'
          categories = (self.settings['preferences']['phrase_categories'] || [])
          cat = 'default' if !categories.include?(cat) && cat != 'default' && cat != 'journal'
          id = action['id'] || (rand(999).to_s + (Time.now.to_i % 1000).to_s + self.settings['vocalizations'].length.to_s)
          if cat == 'journal'
            LogSession.process_as_follow_on({
              'type' => 'journal',
              'vocalization' => action['value'],
              'category' => cat,
              'ts' => action['ts'] || Time.now.to_i,
              'id' => id
            }, {'user' => self, 'author' => non_user_params['updater'] || self, 'device' => non_user_params['device'] || self.devices.first}.with_indifferent_access)
          end
      
          self.settings['vocalizations'].unshift({
            'list' => action['value'],
            'category' => cat,
            'ts' => action['ts'] || Time.now.to_i,
            'id' => id
          })
          journal_cutoff = 2.weeks.ago
          self.settings['vocalizations'] = self.settings['vocalizations'].select{|v| v['category'] != 'journal' || (v['ts'] && v['ts'] > journal_cutoff.to_i) || v['id'] == id }
        elsif action['action'] == 'reorder_vocalizations'
          new_list = []
          journal_cutoff = 2.weeks.ago
          list = (self.settings['vocalizations'] || []).select{|v| v['category'] != 'journal' || (v['ts'] && v['ts'] > journal_cutoff.to_i) || v['id'] == id }
          action['value'].split(',').each do |id|
            item = list.find{|v| v['id'] == id }
            if item
              list -= [item]
              new_list << item
            end
          end
          new_list += list
          self.settings['vocalizations'] = new_list
        elsif action['action'] == 'remove_vocalization'
          self.settings['vocalizations'] = (self.settings['vocalizations'] || []).select{|v| v['id'] != action['value']}
        elsif action['action'] == 'add_contact'
          self.settings['contacts'] ||= []
          if action['value'] && action['value']['contact']
            hash = nil
            while !hash || self.settings['contacts'].detect{|c| c['hash'] == hash}
              hash = GoSecure.nonce('contact_hash')[0, 8]
            end
            contact_type = action['value']['contact'].match(/\@/) ? 'email' : 'sms'
            image_url = action['value']['image_url']
            if !image_url
              bucket = ENV['STATIC_S3_BUCKET'] || "coughdrop"
              id = hash.hex.to_i
              image_url = "https://#{bucket}.s3.amazonaws.com/avatars/avatar-#{id % 10}.png"
            end
            action['value']['contact'].strip!
            ref = action['value']['contact'].strip.downcase
            ref = ref.gsub(/[^\d\+\,]/, '') if contact_type == 'sms'
            existing = self.settings['contacts'].find{|c| c['ref'] == ref }
            if existing
              existing['email'] = contact_type == 'email' && action['value']['contact']
              existing['cell_phone'] = contact_type == 'sms' && action['value']['contact']
              existing['name'] = action['value']['name']
              existing['image_url'] = image_url
            else
              self.settings['contacts'] << {
                'contact_type' => contact_type,
                'email' => contact_type == 'email' && action['value']['contact'],
                'hash' => hash,
                'ref' => ref,
                'cell_phone' => contact_type == 'sms' && action['value']['contact'],
                'name' => action['value']['name'],
                'image_url' => image_url
              }
            end
          end
        elsif action['action'] == 'remove_contact'
          self.settings['contacts'] ||= []
          self.settings['contacts'] = self.settings['contacts'].select{|c| c['hash'] != action['value'] }
        end
      end
    end
    if params['preferences'] && params['preferences']['cookies'] == true
      self.settings['preferences']['protected_user'] = false
    end
    self.settings['preferences']['stretch_buttons'] = nil if self.settings['preferences']['stretch_buttons'] == 'none'
    self.settings['preferences']['progress'] ||= {}
    if params['preferences'] && params['preferences']['progress']
      PROGRESS_PARAMS.each do |attr|
        self.settings['preferences']['progress'][attr] = params['preferences']['progress'][attr] if params['preferences']['progress'][attr]
      end
      if self.settings['preferences']['progress']['board_intros']
        self.settings['preferences']['progress']['board_intros'] = self.settings['preferences']['progress']['board_intros'].uniq
      end
    end
    if params['preferences'] && params['preferences']['requested_phrase_changes']
      (params['preferences']['requested_phrase_changes'] || []).each do |change|
        pieces = (change || "").to_s.split(/:/, 2)
        self.settings['preferences']['requested_phrases'] ||= []
        if pieces[0] == 'add'
          self.settings['preferences']['requested_phrases'] += [pieces[1]]
        elsif pieces[0] == 'remove'
          self.settings['preferences']['requested_phrases'] -= [pieces[1]]
        end
        self.settings['preferences']['requested_phrases'].uniq!
      end
    end
    
    @do_track_boards = true
    process_sidebar_boards(params['preferences']['sidebar_boards'], non_user_params) if params['preferences'] && params['preferences']['sidebar_boards']
    process_home_board(params['preferences']['home_board'], non_user_params) if params['preferences'] && params['preferences']['home_board'] && params['preferences']['home_board']['id']
    process_device(params['preferences']['device'], non_user_params) if params['preferences'] && params['preferences']['device']
    
    if non_user_params['premium_until']
      self.clear_existing_subscription
      if non_user_params['premium_until'] == 'forever'
        self.settings['subscription']['never_expires'] = true
        self.expires_at = nil
      end
    end
    
    if params['supervisee_code']
      if !self.id
        add_processing_error("can't modify supervisees on create") 
        return false
      end
      if !self.link_to_supervisee_by_code(params['supervisee_code'])
        add_processing_error("supervisee add failed") 
        return false
      end
    end
    if params['supervisor_key']
      if !self.id
        add_processing_error("can't modify supervisors on create") 
        return false
      end
      if !self.process_supervisor_key(params['supervisor_key'])
        add_processing_error("supervisor update failed")
        return false
      end
    end
    
    self.settings['pending'] = non_user_params[:pending] if self.settings['pending'] != false && non_user_params[:pending] != nil
    self.settings['public'] = !!params['public'] if params['public'] != nil
    self.settings['admin'] = !!non_user_params['admin'] if non_user_params['admin'] != nil
    if params['password'] && params['password'] != ""
      if !self.settings['password'] || valid_password?(params['old_password'], params['password']) || non_user_params[:allow_password_change]
        Rails.logger.warn("ACTION PROCESS PARAMS USER------------------------valid_password?, params['old_password'], params['password']: #{valid_password?(params['old_password'])}, #{params['old_password']}, #{params['password']}")

        @password_changed = !!self.settings['password']
        self.generate_password(params['password'])
      else
        Rails.logger.warn("ACTION PROCESS PARAMS USER ELSE ERROR------------------------valid_password?, params['old_password'], params['password']: #{valid_password?(params['old_password'])}, #{params['old_password']}, #{params['password']}")

        add_processing_error("incorrect current password")
        return false
      end
    end
    new_user_name = nil
    new_user_name = self.generate_user_name(non_user_params[:user_name], false) if non_user_params[:user_name]
    if !self.user_name
      new_user_name = self.generate_user_name(params['user_name'], false) if params['user_name'] && params['user_name'].length > 0
    end
    if new_user_name
      self.user_name = new_user_name.downcase
      self.settings['display_user_name'] = new_user_name
    end
    true
  end

  def private_logging?
    !!(self.settings && self.settings['preferences'] && self.settings['preferences']['private_logging'])
  end

  def logging_cutoff_for(user, code)
    if self.settings['preferences']['logging_cutoff']
      if self.settings['preferences']['logging_code'] && code == self.settings['preferences']['logging_code']
        return  nil
      elsif self.settings['preferences']['logging_permissions'] && self.settings['preferences']['logging_permissions'][user.global_id]
        # options for manually granting temporary access, or longer-term access to specific supervisors
        exp = self.settings['preferences']['logging_permissions'][user.global_id]['expires']
        if exp
          if exp > Time.now.to_i
            return self.settings['preferences']['logging_permissions'][user.global_id]['cutoff']
          else
            self.settings['preferences']['logging_cutoff']
          end
        else
          return self.settings['preferences']['logging_permissions'][user.global_id]['cutoff']
        end
      else
        self.settings['preferences']['logging_cutoff']
      end
    else
      nil
    end
  end

  def update_home_board_inflections
    board = Board.find_by_path(self.settings['preferences']['home_board']['id']) if self.settings['preferences'] && self.settings['preferences']['home_board']
    if board
      board.schedule(:check_for_parts_of_speech_and_inflections, true)
      Board.find_all_by_global_id(board.settings['downstream_board_ids'] || []).each do |brd|
        brd.schedule(:check_for_parts_of_speech_and_inflections, true)
      end
    end
    ((self.settings['preferences'] || {})['sidebar_boards'] || []).each do |brd|
      board = Board.find_by_path(brd['key'])
      board.schedule(:check_for_parts_of_speech_and_inflections, true) if board
    end
  end

  def lookup_contact(user_id)
    return nil unless user_id
    a, b = user_id.split(/x/)
    contact = b || a
    res = (self.settings['contacts'] || []).detect{|c| c && c['hash'] == contact}
    res['id'] = "#{self.global_id}x#{res['hash']}" if res
    res
  end
  
  def display_user_name
    (self.settings && self.settings['display_user_name']) || self.user_name
  end
  
  def process_device(device, non_user_params)
    device_key = (non_user_params['device'] && non_user_params['device'].unique_device_key) || 'default'    
    if device
      self.settings['preferences']['devices'] ||= {}
      # Since 'browser' is a single device, it's possible that the voice_uri set for one
      # computer won't match the voice_uri needed for a different computer. So this keeps
      # a list of recent voice_uris and the client just uses the most recent one.
      voice_uris = ((self.settings['preferences']['devices'][device_key] || {})['voice'] || {})['voice_uris'] || []
      if device['voice'] && device['voice']['voice_uri']
        voice_uris = [device['voice']['voice_uri']] + voice_uris
        device['voice']['voice_uris'] = voice_uris.uniq[0, 10]
        device['voice'].delete('voice_uri')
      end
      if non_user_params['device'] && device['long_token'] != nil
        non_user_params['device'].settings['long_token'] = !!device['long_token']
        non_user_params['device'].settings['long_token_set'] = true
        if device['asserted']
          non_user_params['device'].settings.delete('temporary_device')
          # Eval accounts are only allowed to be logged into one device at a time
          # so invalidate all other app logins when one is asserted
          # (not when logging in on a browser, just in an app)
          if self.eval_account? && non_user_params['device'].token_type == :app
            other_devices = Device.where(user_id: self.id, developer_key_id: 0).select{|d| d.token_type == :app && d != non_user_params['device'] }
            other_devices.each{|d| d.invalidate_keys! }
          end
        end
        non_user_params['device'].save
      end
      device['voice']['voice_uris'].uniq! if device['voice'] && device['voice']['voice_uris']
      device['alternate_voice']['voice_uris'].uniq! if device['alternate_voice'] && device['alternate_voice']['voice_uris']

      # For eye gaze users we will auto-enable the status so they can see eye status
      if device['dwell'] && !device['dwell_type']
        device['dwell_type'] = 'eyegaze'
      end
      if device['dwell'] && device['dwell_type'] == 'eyegaze'
        self.settings['preferences']['blank_status'] = true
      end

      self.settings['preferences']['devices'][device_key] ||= {}
      device.each do |key, val|
#         if self.settings['preferences']['devices']['default'][key] == device[key]
#           self.settings['preferences']['devices'][device_key].delete(key)
#         else
          self.settings['preferences']['devices'][device_key][key] = val
#         end
      end
    end
  end

  def copy_to_home_board(home_board, updater_id, symbol_library)
    original = home_board && Board.find_by_path(home_board['id'])
    updater = User.find_by_path(updater_id)
    return unless original
    # First, if the user already has a copy as their home board, then stop
    current_home = self.settings['preferences']['home_board'] && Board.find_by_path(self.settings['preferences']['home_board']['id'])
    if current_home && current_home.parent_board == original && ((current_home.settings['swapped_library'] || 'original') == (symbol_library || 'original'))
      return true
    elsif current_home && current_home.global_id(true) == original.global_id
      return true
    end
    # Second, if the user already has a copy not as their home bord, then set that
    home = self.boards.where(parent_board: original).order('id DESC').first
    if home && ((home.settings['swapped_library'] || 'original') == (symbol_library || 'original'))
      self.settings['preferences']['home_board'] = {
        'id' => home.global_id,
        'key' => home.key
      }
      self.settings['preferences']['home_board']['locale'] = home_board['locale'] || home.settings['locale']
      self.settings['preferences']['home_board']['level'] = home_board['level'] if home_board['level']
      self.save
      self.schedule_audit_protected_sources
      return true
    end
    # Finally, create a brand new copy (or shallow clone)
    if home_board['shallow'] && (original.public? || original.allows?(updater, 'edit'))
      if !original.public?
        # TODO: seems like if any sub-boards aren't public then it should be shared as well
        original.share_with(self, true)
        if self.settings['available_private_board_ids']
          self.settings['available_private_board_ids']['generated'] = 0
          self.save
        end
        self.update_available_boards
      end
      # Shallow clone home boards should be remembered even if no longer set as home
      ue = UserExtra.find_or_create_by(user: self)
      ue.settings['replaced_roots'] ||= {}
      ue.settings['replaced_roots'][original.global_id(true)] = {
        'id' => "#{original.global_id(true)}-#{self.global_id}",
        'key' => "#{self.user_name}/my:#{original.key.sub(/\//, ':')}"
      }
      ue.save
      new_home = Board.find_by_global_id("#{original.global_id}-#{self.global_id}")
    else
      new_home = original.copy_for(self)
      self.copy_board_links(old_board_id: original.global_id, new_board_id: new_home.global_id, ids_to_copy: [], auth_user: updater, user_for_paper_trail: "user:#{updater.global_id}", copier_id: updater.global_id, swap_library: symbol_library)
    end
    self.settings['preferences']['home_board'] = {
      'id' => new_home.global_id,
      'key' => new_home.key
    }
    self.settings['preferences']['home_board']['locale'] = home_board['locale'] || new_home.settings['locale']
    self.settings['preferences']['home_board']['level'] = home_board['level'] if home_board['level']
    self.save
    self.schedule_audit_protected_sources
    return true
  end

  def schedule_audit_protected_sources
    ra_cnt = RemoteAction.where(path: "#{self.global_id}", action: 'audit_protected_sources').count
    RemoteAction.create(path: "#{self.global_id}", act_at: 10.minutes.from_now, action: 'audit_protected_sources') if ra_cnt == 0
  end
  
  def process_home_board(home_board, non_user_params)
    board = home_board && Board.find_by_path(home_board['id'])
    board_updater = non_user_params['updater']
    if home_board['copy'] && home_board['copy_from_org']
      org = Organization.find_by_global_id(home_board['copy_from_org'])
      if org && non_user_params['updater']
        if Organization.attached_orgs(non_user_params['updater']).map{|o| o['id'] }.include?(org.global_id)
          non_user_params['org'] = org 
          board_updater = board.user
        end
      end
    end
    json = (self.settings['preferences']['home_board'] || {}).slice('id', 'key').to_json
    org_allowed_board = non_user_params['org'] && (non_user_params['org'].home_board_keys || []).include?(board.key)
    if board && board.allows?(self, 'view') && !home_board['copy']
      self.settings['preferences']['home_board'] = {
        'id' => board.global_id,
        'key' => board.key
      }
      self.settings['preferences']['home_board']['locale'] = home_board['locale'] || board.settings['locale']
      self.settings['preferences']['home_board']['level'] = home_board['level'] if home_board['level']
    elsif board && non_user_params['updater'] && (org_allowed_board || board.allows?(non_user_params['updater'], 'share'))
      if home_board['copy']
        if non_user_params['async']
          Progress.schedule(self, :copy_to_home_board, home_board, board_updater.global_id, home_board['symbol_library'])
        else
          self.copy_to_home_board(home_board, board_updater.global_id, home_board['symbol_library'])
        end
        return
      elsif non_user_params['async']
        board.schedule(:process_share, "add_deep-#{self.global_id}", non_user_params['updater'].global_id)
      else
        board.share_with(self, true)
      end
      self.settings['preferences']['home_board'] = {
        'id' => board.global_id,
        'key' => board.key
      }
      self.settings['preferences']['home_board']['locale'] = home_board['locale'] || board.settings['locale']
      self.settings['preferences']['home_board']['level'] = home_board['level'] if home_board['level']
    else
      self.settings['preferences'].delete('home_board')
    end
    if (self.settings['preferences']['home_board'] || {}).slice('id', 'key').to_json != json
      notify('home_board_changed')
      self.schedule_audit_protected_sources
      self.schedule(:update_home_board_inflections)
    end
  end
  
  def process_sidebar_boards(sidebar, non_user_params)
    self.settings['preferences'] ||= {}
    result = []
    sidebar.each do |board|
      if board['alert']
        result.push({
          'name' => board['name'] || 'Alert',
          'alert' => true,
          'special' => true,
          'image' => board['image'] || 'https://opensymbols.s3.amazonaws.com/libraries/arasaac/to%20sound.png'
        })
      elsif board['special'] && board['action']
        opts = {
          'name' => board['name'] || board['action'].split(/\(/)[0],
          'special' => true,
          'action' => board['action'],
          'image' => board['image'] || "https://d18vdu4p71yql0.cloudfront.net/libraries/noun-project/touch_437_g.svg"
        }
        opts['arg'] = board['arg'] if board['arg'] != nil
        result.push(opts);
      else
        record = Board.find_by_path(board['key']) rescue nil
        allowed = record && record.allows?(self, 'view')
        if !allowed && record && non_user_params && non_user_params['updater'] && record.allows?(non_user_params['updater'], 'share')
          record.share_with(self, true)
          allowed = true
        end
        if record && allowed
          brd = {
            'name' => board['name'] || record.settings['name'] || 'Board',
            'key' => board['key'],
            'image' => board['image'] || record.settings['image_url'] || 'https://opensymbols.s3.amazonaws.com//libraries/arasaac/board_3.png',
            'home_lock' => !!board['home_lock']
          }
          brd['locale'] = board['locale'] || record.settings['locale']
          brd['level'] = board['level'] if board['level']
          valid_types = []
          if board['highlight_type'] == 'custom'
            valid_types = ['geos', 'ssids', 'times', 'places']
          elsif board['highlight_type'] == 'locations'
            valid_types = ['geos', 'ssids']
          elsif board['highlight_type'] == 'times'
            valid_types = ['times']
          elsif board['highlight_type'] == 'places'
            valid_types = ['places']
          else
            board.delete('highlight_type')
          end
          brd['highlight_type'] = board['highlight_type'] if board['highlight_type']
          if board['ssids'] && valid_types.include?('ssids')
            board['ssids'] = board['ssids'].split(/,/) if board['ssids'].is_a?(String)
            ssids = board['ssids'].map{|s| process_string(s) } 
            brd['ssids'] = ssids if ssids.length > 0
          end
          if board['geos'] && valid_types.include?('geos')
            geos = []
            board['geos'] = board['geos'].split(/;/) if board['geos'].is_a?(String)
            board['geos'].each do |geo|
              geo = geo.split(',') if geo.is_a?(String)
              if geo[0] && geo[1]
                geos << [geo[0].to_f, geo[1].to_f]
              end
            end
            brd['geos'] = geos if geos.length > 0
          end
          if board['times'] && valid_types.include?('times')
            board['times'] = board['times'].split(/;/).map{|t| t.split(/-/) } if board['times'].is_a?(String)
            times = []
            board['times'].each do |start_time, end_time|
              parts = [start_time, end_time].map do |time|
                time_pieces = time.sub(/[ap]m$/, '').split(/:/).map{|p| p.to_i }
                if time.match(/[ap]m$/)
                  if time_pieces[0] == 12 && time.match(/am$/)
                    time_pieces[0] = 0
                  elsif time_pieces[0] < 12 && time.match(/pm$/)
                    time_pieces[0] += 12
                  end
                end
                res = time_pieces[0] < 10 ? "0" : ""
                res += time_pieces[0].to_s
                res += time_pieces[1] < 10 ? ":0" : ":"
                res += time_pieces[1].to_s
              end              
              times.push([parts[0], parts[1]]) if parts[0] && parts[1]
            end
            brd['times'] = times if times.length > 0
          end
          if board['places'] && valid_types.include?('places')
            board['places'] = board['places'].split(/,/) if board['places'].is_a?(String)
            places = board['places'].map{|p| process_string(p) }
            brd['places'] = places if places.length > 0
          end
          brd.delete('highlight_type') unless brd['geos'] || brd['ssids'] || brd['times'] || brd['places']
          result.push(brd)
        end
      end
    end

    if result.length == 0
      self.settings['sidebar_changed'] = true
      self.settings['preferences'].delete('sidebar_boards')
    else
      result = result.uniq{|b| b['special'] ? (b['alert'].to_s + "_" + b['action'].to_s + "_" + b['arg'].to_s) : b['key'] }
      pre_json = self.settings['preferences']['sidebar_boards'].to_json
      self.settings['sidebar_changed'] = true if pre_json != result.to_json
      self.settings['preferences']['sidebar_boards'] = result
      self.settings['preferences']['prior_sidebar_boards'] ||= []
      self.settings['preferences']['prior_sidebar_boards'] += result
      self.settings['preferences']['prior_sidebar_boards'].uniq!{|b| b['alert'] ? 'alert' : b['key'] }
    end
  end
  
  def sidebar_boards
    res = (self.settings && self.settings['preferences'] && self.settings['preferences']['sidebar_boards']) || []
    res = User.default_sidebar_boards if res.length == 0
    res
  end
  
  def admin?
    self.settings['admin'] == true || Organization.admin_manager?(self)
  end
  
  def self.default_sidebar_boards
    [
      {'name' => "Yes/No", 'key' => 'example/yesno', 'image' => 'https://opensymbols.s3.amazonaws.com/libraries/arasaac/yes_2.png', 'home_lock' => false},
      {'name' => "Inflections", 'key' => 'example/inflections', 'image' => 'https://opensymbols.s3.amazonaws.com/libraries/arasaac/verb.png', 'home_lock' => false},
      {'name' => "Keyboard", 'key' => 'example/keyboard', 'image' => 'https://opensymbols.s3.amazonaws.com/libraries/noun-project/Computer%20Keyboard-19d40c3f5a.svg', 'home_lock' => false},
      {'name' => 'Social', 'key' => 'mbaud12/senner-baud-greetings', 'image' => 'https://opensymbols.s3.amazonaws.com/libraries/arasaac/greet_2.png', 'home_lock' => false},
      {'name' => "Alert", 'special' => true, 'alert' => true, 'image' => 'https://opensymbols.s3.amazonaws.com/libraries/arasaac/to%20sound.png'}
    ]
  end

  def notify_of_changes
    if @password_changed
      UserMailer.schedule_delivery(:password_changed, self.global_id)
      @password_changed = false
    end
    if @email_changed
      # TODO: should have confirmation flow for new email address
      UserMailer.schedule_delivery(:email_changed, self.global_id)
      @email_changed = false
    end
    if @opt_out
      AdminMailer.schedule_delivery(:opt_out, self.global_id, @opt_out)
      @opt_out = false
    end
    true
  end

  def enabled_protected_sources(include_supervisees=false)
    cache_key = "protected_sources/#{include_supervisees}"
    res = get_cached(cache_key)
    return res if res
    self.settings ||= {}
    res = []
    res << 'lessonpix' if self && Uploader.lessonpix_credentials(self)
    res << 'pcs' if self && self.subscription_hash['extras_enabled']
    res << 'lessonpix' if self && self.subscription_hash['extras_enabled']
    res << 'symbolstix' if self && self.subscription_hash['extras_enabled']
    if include_supervisees
      self.supervisees.each do |u| 
        res += u.enabled_protected_sources 
      end
    end
    res = res.uniq
    set_cached(cache_key, res)
    res
  end
  
  def add_user_notification(args)
    args = args.with_indifferent_access
    self.settings['user_notifications'] ||= []
    self.settings['user_notifications'].reject!{|n| n['type'] == args['type'] && n['id'] == args['id'] }
    args['added_at'] = Time.now.utc.iso8601
    self.settings['user_notifications'].unshift(args)
    self.settings['user_notifications'] = self.settings['user_notifications'][0, 10]
    self.save
  end
  
  def handle_notification(notification_type, record, args)
    if notification_type == 'push_message'
      if record.user_id == self.id
        if record.data['notify_user']
          self.settings['unread_alerts'] = (self.settings['unread_alerts'] || 0) + 1
          self.settings['last_alert_access'] = (record.started_at || 0).to_i
        end
        if !record.data['notify_user_only']
          self.settings['unread_messages'] = (self.settings['unread_messages'] || 0) + 1
          # last_message_read is a bad name, but it marks the most-recent
          # unread or view by the user, that way we have something more 
          # reliable to set then explicitly setting the unread count to 0,
          # which may happen inadvertently with multiple devices
          self.settings['last_message_read'] = (record.started_at || 0).to_i
        end
        self.save
      end
      share_index = (record.data['share_user_ids'] || []).index(self.global_id)
      id = record.global_id
      if share_index && record.reply_nonce
        id = "#{record.global_id}x#{record.reply_nonce}#{Utterance.to_alpha_code(share_index)}"
      end
      self.add_user_notification({
        :id => record.global_id,
        :type => notification_type,
        :user_name => record.user.user_name,
        :author_user_name => record.author.user_name,
        :text => record.data['note']['text'],
        :occurred_at => record.started_at.iso8601
      })
      UserMailer.schedule_delivery(:log_message, self.global_id, record.global_id)
    elsif notification_type == 'home_board_changed'
      hb = (record.settings && record.settings['preferences'] && record.settings['preferences']['home_board']) || {}
      self.add_user_notification({
        :type => 'home_board_changed',
        :occurred_at => record.updated_at.iso8601,
        :user_name => record.user_name,
        :key => hb['key'],
        :id => hb['id']
      })
    elsif notification_type == 'board_buttons_changed'
      my_ubcs = UserBoardConnection.where(:user_id => self.id, :board_id => record.id)
      supervisee_ubcs = UserBoardConnection.where(:user_id => supervisees.map(&:id), :board_id => record.id)
      self.add_user_notification({
        :type => notification_type,
        :occurred_at => record.updated_at.iso8601,
        :for_user => my_ubcs.count > 0,
        :for_supervisees => supervisee_ubcs.map{|ubc| ubc.user.user_name }.sort,
        :previous_revision => args['revision'],
        :name => record.settings['name'],
        :key => record.key,
        :id => record.global_id
      })
    elsif notification_type == 'org_removed'
      self.add_user_notification({
        :type => 'org_removed',
        :org_id => record.global_id,
        :org_name => record.settings['name'],
        :user_type => args['user_type'],
        :occurred_at => args['removed_at']
      })
    elsif notification_type == 'utterance_shared'
      pref = (self.settings && self.settings['preferences'] && self.settings['preferences']['share_notifications']) || 'email'
      sharer = User.find_by_global_id(args['sharer']['user_id'])
      # Utterance.deliver_message
      record.deliver_message(pref, self, args, sharer)
      if pref == 'none'
        return
      end
      self.add_user_notification({
        :type => notification_type,
        :occurred_at => record.updated_at.iso8601,
        :sharer_user_name => args['sharer']['user_name'],
        :text => args['text'],
        :id => record.global_id
      })
    elsif notification_type == 'log_summary'
      self.next_notification_at = self.next_notification_schedule
      self.save
      UserMailer.schedule_delivery(:log_summary, self.global_id)
    elsif notification_type == 'badge_awarded'
      self.add_user_notification({
        :type => 'badge_awarded',
        :occurred_at => record.awarded_at,
        :user_name => record.user.user_name,
        :badge_name => record.data['name'],
        :badge_level => record.level,
        :id => record.global_id
      })
      if self.settings['preferences'] && self.settings['preferences']['goal_notifications'] != 'disabled'
        UserMailer.schedule_delivery(:badge_awarded, self.global_id, record.global_id)
      end
    end
  end
  
  def next_notification_schedule
    res = Time.now.utc
    cutoff = res + 24.hours
    if !self.settings || !self.settings['preferences'] || !self.settings['preferences']['notification_frequency'] || self.settings['preferences']['notification_frequency'] == ''
      return nil
    elsif self.settings && self.settings['preferences'] && self.settings['preferences']['notification_frequency'] == '1_month'
    else
      res -= 24.hours
      already_friday_or_saturday = res.wday == 5 || res.wday == 6
      # friday or saturday in the US
      friday_or_saturday = (self.id || 0) % 2 == 0 ? 5 : 6
      while res.wday != friday_or_saturday
        if already_friday_or_saturday
          res += 1.day
        else
          res -= 1.day
        end
      end
    end
    if self.settings && self.settings['preferences'] && self.settings['preferences']['notification_frequency'] == '2_weeks'
      cutoff += 8.days
    end
          # 6pm eastern thru 10pm eastern
    hours = [22, 23, 0, 1, 2]
    hour_idx = (self.id || 0) % hours.length
    hour = hours[hour_idx]
    if hour < 20
      res += 1.day
    end
    min = (self.id || 0) % 2 == 0 ? 0 : 30
    res = res.change(:hour => hour, :min => min)
    # set to a nice happy time of day
    while res < cutoff
      if self.settings && self.settings['preferences'] && self.settings['preferences']['notification_frequency'] == '2_weeks'
        # since the cutoff was extended, it'll get to 2 weeks via cutoff, this just makes it a little cleaner
        res += 7.days
      elsif self.settings && self.settings['preferences'] && self.settings['preferences']['notification_frequency'] == '1_month'
        res += 1.month
      else
        res += 7.days
      end
    end
    res
  end
  
  def default_listeners(notification_type)
    if notification_type == 'home_board_changed'
      ([self] + self.supervisors).uniq.map(&:record_code)
    elsif notification_type == 'log_summary'
      [self].map(&:record_code)
    else
      []
    end
  end
  
  def replace_board(opts)
    opts = opts.with_indifferent_access
    starting_old_board_id = opts[:old_board_id]
    starting_new_board_id = opts[:new_board_id]
    ids_to_copy = opts[:ids_to_copy] || []
    update_inline = opts[:update_inline] || false
    make_public = opts[:make_public] || false
    whodunnit = opts[:user_for_paper_trail] || nil

    prior = PaperTrail.request.whodunnit
    PaperTrail.request.whodunnit = whodunnit if whodunnit
    starting_old_board = Board.find_by_path(starting_old_board_id)
    starting_new_board = Board.find_by_path(starting_new_board_id)
    valid_ids = nil
    if ids_to_copy && ids_to_copy.length > 0
      valid_ids = ids_to_copy.split(/,/)
      valid_ids = nil if valid_ids.length == 0
    end
    Board.replace_board_for(self, {
      :starting_old_board => starting_old_board, 
      :starting_new_board => starting_new_board, 
      :old_default_locale => opts[:old_default_locale],
      :new_default_locale => opts[:new_default_locale],
      :copy_prefix => opts[:copy_prefix],
      :valid_ids => valid_ids, 
      :update_inline => update_inline, 
      :copier => User.find_by_path(opts[:copier_id]),
      :make_public => make_public, 
      :new_owner => opts[:new_owner],
      :disconnect => opts[:disconnect],
      :authorized_user => User.whodunnit_user(PaperTrail.request.whodunnit)
    })
    ids = [starting_old_board_id]
    ids += (starting_old_board.reload.downstream_board_ids || []) if starting_old_board
    # This was happening too slowly/unreliably in a separate bg job
#    button_set = BoardDownstreamButtonSet.update_for(starting_new_board.global_id, true)
    {'affected_board_ids' => ids.uniq}
  ensure
    PaperTrail.request.whodunnit = prior
  end
  
  def copy_board_links(opts)
    opts = opts.with_indifferent_access
    starting_old_board_id = opts[:old_board_id]
    starting_new_board_id = opts[:new_board_id]
    ids_to_copy = opts[:ids_to_copy] || []
    make_public = opts[:make_public] || false
    whodunnit = opts[:user_for_paper_trail] || nil
    swap_library = opts[:swap_library]

    prior = PaperTrail.request.whodunnit
    PaperTrail.request.whodunnit = whodunnit if whodunnit
    starting_old_board = Board.find_by_path(starting_old_board_id)
    starting_new_board = Board.find_by_path(starting_new_board_id)
    valid_ids = nil
    if ids_to_copy && ids_to_copy.length > 0
      valid_ids = ids_to_copy.split(/,/)
      valid_ids = nil if valid_ids.length == 0
    end
    user = self
    change_hash = Board.copy_board_links_for(user, {
      :starting_old_board => starting_old_board, 
      :starting_new_board => starting_new_board, 
      :old_default_locale => opts[:old_default_locale],
      :new_default_locale => opts[:new_default_locale],
      :copy_prefix => opts[:copy_prefix],
      :valid_ids => valid_ids, 
      :copier => User.find_by_path(opts[:copier_id]),
      :make_public => make_public, 
      :new_owner => opts[:new_owner],
      :disconnect => opts[:disconnect],
      :authorized_user => opts[:auth_user] || User.whodunnit_user(PaperTrail.request.whodunnit)
    }) || {}
    updated_ids = [starting_new_board_id]
    ids = [starting_old_board_id]
    ids += (starting_old_board.reload.downstream_board_ids || []) if starting_old_board
    ids.each do |id|
      updated_ids << change_hash[id][:id] if change_hash[id]
    end
    res = {
      'affected_board_ids' => ids.uniq,
      'new_board_ids' => updated_ids.uniq
    }
    if swap_library && swap_library != 'default' && swap_library != 'original'
      ids = res['new_board_ids']
      ids.instance_variable_set('@skip_keyboard', true)
      swap_library.instance_variable_set('@skip_swapped', true)
      starting_new_board.reload
      starting_new_board.swap_images(swap_library, self, ids)
      res['swap_library'] = swap_library
    end
    PaperTrail.request.whodunnit = prior
    # This was happening too slowly/unreliably in a separate bg job
    self.update_available_boards
    # button_set = BoardDownstreamButtonSet.update_for(starting_new_board.global_id, true)
    res
  # ensure
  #   PaperTrail.request.whodunnit = prior
  end

  def self.whodunnit_user(whodunnit)
    if whodunnit && whodunnit.match(/^user:/)
      User.find_by_path(whodunnit.split(/[:\.]/)[1])
    else
      nil
    end
  end
  
  def user_token
    token = "#{self.global_id}-"
    token = token + GoSecure.sha512(token, 'user_token verifier')[0, 30]
    token
  end
  
  def self.find_by_token(token)
    return nil unless token
    user_id, hash = token.split(/-/)
    return nil unless user_id && hash
    verifier = GoSecure.sha512("#{user_id}-", 'user_token verifier')[0, 30]
    return nil unless hash == verifier
    User.find_by_global_id(user_id)
  end
    
  def notify_on(attributes, notification_type)
    # TODO: ...
  end

  def self.flush_old_versions
    if PaperTrail::Version.where({item_type: 'LogSession'}).where(['created_at < ?', 1.week.ago]).count > 300
      PaperTrail::Version.where({item_type: 'LogSession'}).where(['created_at < ?', 1.week.ago]).delete_all
    end
    if PaperTrail::Version.where({item_type: 'User'}).where(['created_at < ?', 1.months.ago]).count > 300
      PaperTrail::Version.where({item_type: 'User'}).where(['created_at < ?', 1.months.ago]).delete_all
    end
    if PaperTrail::Version.where({item_type: 'Board'}).where(['created_at < ?', 6.months.ago]).count > 300
      PaperTrail::Version.where({item_type: 'Board'}).where(['created_at < ?', 6.months.ago]).delete_all
    end

  end
end
