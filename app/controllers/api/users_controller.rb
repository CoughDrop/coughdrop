class Api::UsersController < ApplicationController
  extend ::NewRelic::Agent::MethodTracer

  before_action :require_api_token, :except => [:update, :show, :create, :confirm_registration, :forgot_password, :password_reset, :protected_image, :subscribe, :activate_button]
  def show
    user = User.find_by_path(params['id'])
    user_device = (user && @api_user && @api_user.global_id == user.global_id) && Device.find_by_global_id(@api_device_id)
    allowed = false
    return unless exists?(user, params['id'])
    if user.registration_code && params['confirmation'] == user.registration_code
      allowed = true
      @include_subscription = true
    end
    self.class.trace_execution_scoped(['user/permission_check']) do
      allowed ||= allowed?(user, 'view_existence')
    end
    return unless allowed
    json = {}
    self.class.trace_execution_scoped(['user/json_render']) do
      json = JsonApi::User.as_json(user, :wrapper => true, :permissions => @api_user, :device => user_device, :include_subscription => @include_subscription)
    end
    
    render json: json.to_json
  end
  
  def sync_stamp
    user = User.select('id', 'sync_stamp', 'updated_at', 'badges_updated_at', 'created_at').find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    if user.global_id != @api_user.global_id
      return unless allowed?(user, 'never_allow')
    end
    render json: {sync_stamp: (user.sync_stamp || user.updated_at).utc.iso8601, badges_updated_at: (user.badges_updated_at || user.created_at).utc.iso8601}
  end

  def valet_credentials
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'delete')
    if !user.settings['valet_password']
      return unless allowed?(user, 'never_allow')
    end
    nonce = GoSecure.nonce('valet_hash_password')[0, 5]
    password = user.valet_temp_password(nonce)
    credentials = "model-#{user.global_id}:#{password.gsub(/\?:\#/, '-')}"
    url = "#{JsonApi::Json.current_host}/login?#{credentials}"
    render json: {user_name: "model@#{user.global_id.sub(/_/, '.')}", password: password, url: url}
  end
  
  def places
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'model')
    render json: Geolocation.find_places(params['latitude'], params['longitude'])
  end

  def ws_encrypt
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'supervise')
    str = GoSecure.encrypt("#{params['user_id']}.#{params['text']}", 'ws_content_encrypted', ENV['CDWEBSOCKET_ENCRYPTION_KEY']).map(&:strip).join('$')
    render json: {encoded: str, user_id: user.global_id}
  end

  def ws_decrypt
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'supervise')
    str, iv = params['text'].split(/\$/)
    user_id, text = GoSecure.decrypt(str, iv, 'ws_content_encrypted', ENV['CDWEBSOCKET_ENCRYPTION_KEY']).split(/\./, 2) rescue nil
    return api_error(400, {error: 'invalid decryption'}) unless user_id && text
    return api_error(400, {error: 'user_id mismatch'}) unless user_id == user.global_id
    render json: {decoded: text, user_id: user.global_id}    
  end

  def ws_lookup
    obfuscated_user_id = params['user_id']
    return api_error(400, {error: 'user_id required'}) unless !obfuscated_user_id.blank?
    str, iv = obfuscated_user_id.sub(/^me\$/, '').split(/\$/)
    user_id, device_id = GoSecure.decrypt(str, iv, 'ws_device_id_encrypted', ENV['CDWEBSOCKET_ENCRYPTION_KEY']).split(/\./) rescue nil
    return api_error(400, {error: 'invalid decryption'}) unless user_id && device_id
    user = User.find_by_path(user_id)
    return unless exists?(user, user_id)
    # Supervisee needs to look up supervisors as well
    if !@api_user.allows?(user, 'supervise')
      return unless allowed?(user, 'supervise')
    end
    render json: {
      user_id: user.global_id,
      user_name: user.user_name,
      device_id: device_id,
      avatar_url: user.generated_avatar_url
    }
  end

  def ws_settings
    # Self should always get the verifier
    # Supervisor should get supervisee ids
    # Org manager should be able to query for individual ids in their org
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'supervise')
    res = {
      user_id: user.global_id,
      ws_user_id: user.global_id
    }

    # We manually set the IV so that device_id remains consistent across 
    # page reloads, and doesn't imply multiple devices to the websocket service
    iv = Digest::SHA2.hexdigest("user_settings_iv_for_" + (@token || @api_user.global_id))[0, 16]
    device_id = GoSecure.encrypt("#{@api_user.global_id}.#{@api_device_id}", 'ws_device_id_encrypted', ENV['CDWEBSOCKET_ENCRYPTION_KEY'], iv).map(&:strip).join('$')
    ts = Time.now.to_i
    if user.global_id == @api_user.global_id
      res[:my_device_id] = "me$#{device_id}"
    else
      res[:my_device_id] = device_id
    end
    code = GoSecure.sha512("#{res[:ws_user_id]}:#{res[:my_device_id]}:#{ts}", "room_join_verifier", ENV['CDWEBSOCKET_SHARED_VERIFIER'])[0, 30]
    res[:verifier] = "#{code}:#{ts}"
    if user.supporter_role?
      sups = user.supervisees
      if sups.length < 20
        res[:supervisees] = sups.map do |sup|
          ws_user_id = sup.global_id
          sup = {
            user_id: sup.global_id,
            ws_user_id: ws_user_id,
          }
          if user.global_id == @api_user.global_id
            sup[:my_device_id] = device_id
            code = GoSecure.sha512("#{ws_user_id}:#{device_id}:#{ts}", "room_join_verifier", ENV['CDWEBSOCKET_SHARED_VERIFIER'])[0, 30]
            sup[:verifier] = "#{code}:#{ts}"
          end
          sup
        end
      end
    end

    render json: res
  end
  
  def index
    lookup = User
    org = nil
    if params['org_id']
      org = Organization.find_by_global_id(params['org_id'])
      return unless allowed?(org, 'edit')
      lookup = org.attached_users('all')
    elsif !Organization.admin_manager?(@api_user)
      return api_error 400, {error: 'admins only'}
    end
    if !params['q']
      return api_error 400, {error: 'q parameter required'}
    end
    query = params['q'].downcase
    users = []
    if org && org.settings['saml_metadata_url']
      user = org.find_saml_alias(params['q'], params['q'].downcase)
      users = [user] if user
    end
    if users.empty?
      if query.match(/@/)
        users = lookup.find_by_email(query)
      else
        users = lookup.where(:user_name => query)
        users = [lookup.find_by_global_id(query)].compact if users.count == 0 && query.match(/^\d+_\d+$/)
        if users.count == 0
          users = lookup.where(["user_name ILIKE ?", "%#{query}%"]).order('user_name')
        end
      end
    end
    render json: JsonApi::User.paginate(params, users)
  end
  
  def update
    user = User.find_by_path(params['id'])
    user_device = (user && @api_user && @api_user.global_id == user.global_id) && Device.find_by_global_id(@api_device_id)
    return unless exists?(user)
    options = {}
    if params['reset_token'] && user.valid_reset_token?(params['reset_token'])
      params['user'] ||= {}
      params['user'] = params['user'].slice('password')
      options[:allow_password_change] = true
      user.used_reset_token!(params['reset_token'])
    elsif params['reset_token'] == 'admin' && user.allows?(@api_user, 'support_actions')
      params['user'] ||= {}
      params['user'] = params['user'].slice('password')
      options[:allow_password_change] = true
      user.used_reset_token!(params['reset_token'])
    elsif user.allows?(@api_user, 'manage_supervision') && !user.allows?(@api_user, 'edit')
      params['user'] ||= {}
      params['user'] = params['user'].slice('supervisor_key')
    else
      return unless allowed?(user, 'edit')
    end
    # we don't want to set device preferences unless the user actually changed device settings
    user_device ||= Device.where(user: @api_user).find_by_global_id(@api_device_id) if params['user'] && params['user']['preference'] && params['user']['preference']['device'] && params['user']['preference']['device']['updated']
    options['device'] = user_device
    options['updater'] = @api_user
      
    if user.process(params['user'], options)
      start_code_progress = user.instance_variable_get('@start_code_progress')
      json = JsonApi::User.as_json(user, :wrapper => true, :permissions => @api_user, :device => user_device)
      if start_code_progress
        json['user']['start_progress'] = JsonApi::Progress.as_json(start_code_progress)
      end
      render json: json.to_json
    else
      api_error 400, {error: 'update failed', errors: user.processing_errors}
    end
  end
  
  def create
    if params['user'] && params['user']['start_code']
      # Validate user.start_code if present and error before trying to create
      code = Organization.parse_activation_code(params['user']['start_code'])
      
      return api_error(400, {error: "invalid start code", start_code_error: true}) if !code || code[:disabled]
    end
    user = User.process_new(params['user'], {:pending => true, :author => @api_user})

    start_progress = nil
    if !user || user.errored?
      return api_error(400, {error: "user creation failed", errors: user && user.processing_errors})
    end
    if params['user']['start_code']
      # Process start code actions once the user is fully created (can't add supervisors beforehand)
      res = Organization.parse_activation_code(params['user']['start_code'], user)

      start_progress = res[:progress]
    end

    UserMailer.schedule_delivery(:confirm_registration, user.global_id)
    UserMailer.schedule_later_delivery(:welcome_confirm_registration, user.global_id)
    UserMailer.schedule_delivery(:new_user_registration, user.global_id)
    ExternalTracker.track_new_user(user)

    d = Device.find_or_create_by(:user_id => user.id, :device_key => 'default', :developer_key_id => 0)

    d.settings['ip_address'] = request.remote_ip
    d.settings['browser'] = true if request.headers['X-INSTALLED-COUGHDROP'] == 'false'
    d.settings['app'] = true if request.headers['X-INSTALLED-COUGHDROP'] == 'true'
    d.settings['user_agent'] = request.headers['User-Agent']
    
    d.generate_token!(!!d.settings['app'])

    res = JsonApi::User.as_json(user, :wrapper => true, :permissions => @api_user || user)
    res['user']['start_progress'] = JsonApi::Progress.as_json(start_progress) if start_progress
    res['meta'] = JsonApi::Token.as_json(user, d)
    render json: res.to_json
  end
  
  def claim_voice
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'edit')
    if user.add_premium_voice(params['voice_id'], params['system'])
      res = {voice_added: true, voice_id: params['voice_id']}
      if params['voice_url']
        res[:download_url] = Uploader.signed_download_url(params['voice_url'])
        res[:download_language_url] = Uploader.signed_download_url(params['language_url']) if params['language_url']
        res[:download_binary_url] = Uploader.signed_download_url(params['binary_url']) if params['binary_url']
      end
      render json: res.to_json
    else
      api_error(400, {error: "no more voices available"})
    end
  end
  
  def start_code
    # post 'start_code'
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'edit')
    return allowed?(user, 'never_allow') unless user.supporter_role?
    if params['delete'] && params['code']
      res = Organization.remove_start_code(user, params['code'])
      return api_error(400, {error: 'code not found'}) unless res
      render json: {code: params['code'], deleted: true}
    else
      code = nil
      begin
        code = Organization.activation_code(user, params['overrides'])
      rescue => e
        err = {error: e.message}
        err[:code_taken] = true if e.message == 'code is taken'
        err[:invalid_board] = true if e.message == 'invalid home board'
        return api_error(400, err)
      end
      api_error(400, {error: 'code generation failed'}) unless code
      render json: {code: code}
    end
  end

  def activate_button
    user = User.find_by_path(params['user_id'])
    return if params['user_id'] != 'nobody' && !exists?(user, params['user_id'])
    return if user && !allowed?(user, 'model')
    board = Board.find_by_path(params['board_id'])
    return unless exists?(board, params['board_id'])
    return unless allowed?(board, 'view')
    button = params['button_id'] && board.buttons.detect{|b| b['id'].to_s == params['button_id'].to_s }
    if !button
      return api_error(400, {error: 'button not found'})
    elsif !button['integration'] || !button['integration']['user_integration_id']
      return api_error(400, {error: 'button integration not configured'})
    end
    associated_user = nil
    if params['associated_user_id']
      supervisee = User.find_by_path(params['associated_user_id'])
      if supervisee && supervisee.allows?(user, 'model')
        associated_user = supervisee
      end
    end
    progress = Progress.schedule(board, :notify, 'button_action', {
      'user_id' => user && user.global_id,
      'immediate' => true,
      'associated_user_id' => (associated_user && associated_user.global_id),
      'button_id' => params['button_id']
    })
    render json: JsonApi::Progress.as_json(progress, :wrapper => true)
  end
  
  def rename
    user = User.find_by_path(params['user_id'])

    return unless exists?(user)
    return unless allowed?(user, 'support_actions')
    return if params['new_key'].blank? && !allowed?(user, 'never_allow')

    if params['new_key'] && params['old_key'] && params['old_key'].downcase == user.user_name && user.rename_to(params['new_key'])
      key = User.clean_path(params['new_key'])
      render json: {rename: true, key: key}.to_json
    else
      api_error(400, {error: "user rename failed", key: params['key'], invalid_name: user.invalid_name_error?, collision: user.collision_error?})
    end
  end
  
  def flush_logs
    user = User.find_by_path(params['user_id'])
    return unless allowed?(user, 'delete')
    return api_error(400, {'flushed' => 'false', 'user_name_math' => (user.user_name == params['user_name']), 'user_id_match' => (user.global_id == params['confirm_user_id'])}) unless user.user_name == params['user_name'] && user.global_id == params['confirm_user_id']
    progress = Progress.schedule(Flusher, :flush_user_logs, user.global_id, user.user_name)
    render json: JsonApi::Progress.as_json(progress, :wrapper => true)
  end
  
  def flush_user
    user = User.find_by_path(params['user_id'])
    return unless allowed?(user, 'delete')
    return api_error(400, {'flushed' => 'false'}) unless user.user_name == params['user_name'] && user.global_id == params['confirm_user_id']
    user.schedule_deletion_at = 36.hours.from_now
    user.save
    Purchasing.cancel_other_subscriptions(user, 'all')
    SubscriptionMailer.deliver_message(:account_deleted, user.global_id)
    AdminMailer.schedule_delivery(:opt_out, user.global_id, 'deleted')
    render json: {flushed: 'pending'}
  end
  
  def hide_device
    user = User.find_by_path(params['user_id'])
    return unless allowed?(user, 'delete')
    device = Device.find_by_global_id(params['device_id'])
    if device && device.user_id == user.id
      device.settings['hidden'] = true
      device.save
      render json: JsonApi::Device.as_json(device, :current_device => Device.find_by_global_id(@api_device_id))
    else
      api_error 400, {error: 'matching device not found'}
    end
  end
  
  def rename_device
    user = User.find_by_path(params['user_id'])
    return unless allowed?(user, 'edit')
    device = Device.find_by_global_id(params['device_id'])
    if device && device.user_id == user.id
      device.settings['name'] = params['device']['name']
      device.save
      render json: JsonApi::Device.as_json(device, :current_device => Device.find_by_global_id(@api_device_id))
    else
      api_error 400, {error: 'matching device not found'}
    end
  end
  
  def word_activities
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'model')
    
    # skip if recently-retrieved
    existing = WordData.activities_for(user, true)
    if existing.instance_variable_get('@fresh')
      render json: existing
    else
      progress = Progress.schedule(WordData, :update_activities_for, user.global_id, true)
      render json: JsonApi::Progress.as_json(progress, :wrapper => true)
    end
  end

  def history
    user_id = nil
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    if user
      return unless allowed?(user, 'admin_support_actions')
      user_id = user.global_id
    elsif @api_user.allows?(@api_user, 'admin_support_action')
      user_id = params['user_id']
    end
    return unless exists?(user_id)
    versions = User.user_versions(user_id)
    render json: JsonApi::UserVersion.paginate(params, versions, {:admin => Organization.admin_manager?(@api_user)})
  end
  
  def supervisors
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'supervise')
    supervisors = user.supervisors
    render json: JsonApi::User.paginate(params, supervisors, limited_identity: true, supervisee: user, prefix: "/users/#{user.global_id}/supervisors")
  end
  
  def supervisees
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'supervise')
    supervisees = user.supervisees
    render json: JsonApi::User.paginate(params, supervisees, limited_identity: true, supervisor: user, prefix: "/users/#{user.global_id}/supervisees")
  end
  
  def subscribe
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])

    admin = Organization.admin
    token = nil
    if params['token'] && params['token'].respond_to?(:to_unsafe_h)
      token = params['token'].to_unsafe_h
    elsif params['token'] && params['token'].respond_to?(:to_h)
      token = params['token'].to_h
    end
    if params['type'] == 'gift_code'
      return require_api_token unless @api_user
      return unless allowed?(user, 'edit')
      progress = Progress.schedule(user, :redeem_gift_token, token['code'])
    elsif['never_expires', 'eval', 'add_1', 'add_5_years', 'manual_supporter', 'add_voice', 'communicator_trial', 'force_logout', 'enable_extras', 'supporter_credit', 'check_remote', 'restore', 'manual_modeler'].include?(params['type'])
      return require_api_token unless @api_user
      return unless allowed?(user, 'admin_support_actions')
      progress = Progress.schedule(user, :subscription_override, params['type'], @api_user && @api_user.global_id)
    else
      if user.registration_code && params['confirmation'] == user.registration_code
      else
        return require_api_token unless @api_user
        return unless allowed?(user, 'edit')
      end
      progress = Progress.schedule(user, :process_subscription_token, token, params['type'], params['code'])
    end
    render json: JsonApi::Progress.as_json(progress, :wrapper => true)
  end
  
  def unsubscribe
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'edit')
    user.settings['subscription'] ||= {}
    user.settings['subscription']['unsubscribe_reason'] = params['reason'] if params['reason']
    user.save_with_sync('unsubscribe')
    progress = Progress.schedule(user, :process_subscription_token, 'token', 'unsubscribe')
    render json: JsonApi::Progress.as_json(progress, :wrapper => true)
  end

  def verify_receipt
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'edit')
    progress = Progress.schedule(user, :verify_receipt, params['receipt_data'])
    render json: JsonApi::Progress.as_json(progress, :wrapper => true)
  end
  
  def replace_board
    user = User.find_by_path(params['user_id'])
    old_board = Board.find_by_path(params['old_board_id'])
    new_board = Board.find_by_path(params['new_board_id'])
    return unless exists?(user, params['user_id']) && exists?(old_board, params['old_board_id']) && exists?(new_board, params['new_board_id'])
    return unless allowed?(user, 'edit') && allowed?(old_board, 'view') && allowed?(new_board, 'view')
    return allowed?(user, 'never_allow') unless new_board.user == user
    
    make_public = params['make_public'] && params['make_public'] == '1' || params['make_public'] == 'true' || params['make_public'] == true
    progress = Progress.schedule(user, :replace_board, {
      old_board_id: params['old_board_id'], 
      new_board_id: params['new_board_id'], 
      old_default_locale: params['old_default_locale'], 
      new_default_locale: params['new_default_locale'], 
      ids_to_copy: params['ids_to_copy'], 
      copy_prefix: params['copy_prefix'],
      update_inline: params['update_inline'], 
      copier_id: @api_user && @api_user.global_id,
      new_owner: params['new_owner'],
      disconnect: params['disconnect'],
      make_public: make_public,
      user_for_paper_trail: user_for_paper_trail
    })
    render json: JsonApi::Progress.as_json(progress, :wrapper => true)
  end
  
  def copy_board_links
    user = User.find_by_path(params['user_id'])
    old_board = Board.find_by_path(params['old_board_id'])
    new_board = Board.find_by_path(params['new_board_id'])
    return unless exists?(user, params['user_id']) && exists?(old_board, params['old_board_id']) && exists?(new_board, params['new_board_id'])
    return unless allowed?(user, 'edit') && allowed?(old_board, 'view') && allowed?(new_board, 'view')
    return allowed?(user, 'never_allow') unless new_board.user == user
    
    make_public = params['make_public'] && params['make_public'] == '1' || params['make_public'] == 'true' || params['make_public'] == true
    progress = Progress.schedule(user, :copy_board_links, {
        old_board_id: params['old_board_id'], 
        new_board_id: params['new_board_id'], 
        old_default_locale: params['old_default_locale'], 
        new_default_locale: params['new_default_locale'], 
        ids_to_copy: params['ids_to_copy'], 
        copy_prefix: params['copy_prefix'],
        make_public: make_public, 
        copier_id: @api_user && @api_user.global_id,
        new_owner: params['new_owner'],
        disconnect: params['disconnect'],
        user_for_paper_trail: user_for_paper_trail,
        swap_library: params['swap_library']      
    })
    render json: JsonApi::Progress.as_json(progress, :wrapper => true)
  end
  
  def board_revisions
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'model')
    roots = []
    if user.settings['preferences']['home_board']
      roots << Board.find_by_global_id(user.settings['preferences']['home_board']['id'])
    end
    roots += Board.find_all_by_path(user.sidebar_boards.map{|b| b['key'] })
    if user.settings['preferences']['sync_starred_boards']
      roots += Board.find_all_by_path(user.settings['starred_board_ids'] || [])
    end
    all_ids = []
    roots.compact.each do |root|
      all_ids << root.global_id
      all_ids += root.downstream_board_ids
    end
    all_ids.uniq!
    res = {}
    Board.select('id, current_revision, key').find_all_by_global_id(all_ids).each do |brd|
      res[brd.global_id] = brd.current_revision
      res[brd.key] = brd.current_revision
    end
    render json: res.to_json
  end

  def boards
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'model')
    ids = params['ids'].split(/,/)
    return api_error(400, {error: 'too many ids'}) if ids.length > 25
    boards = Board.find_all_by_global_id(ids)
    res = []
    boards.select{|b| b.allows?(user, 'view')}.each do |board|
      board.track_usage!
      res << JsonApi::Board.as_json(board, :permissions => @api_user, :wrapper => true, :skip_subs => true)['board']
    end
    render json: res
  end
  
  def confirm_registration
    user = User.find_by_path(params['user_id'])
    if params['resend']
      sent = false
      if user.settings['pending'] != false
        sent = true
        UserMailer.schedule_delivery(:confirm_registration, user.global_id)
      end
      render json: {sent: sent}.to_json
    else
      confirmed = !!(user && !user.settings['pending'])
      if params['code'] && user && params['code'] == user.registration_code
        confirmed = true
        user.update_setting('pending', false)
      end
      render json: {:confirmed => confirmed}.to_json
    end
  end
  
  def forgot_password
    # TODO: throttling...
    user = User.find_by_path(params['key'])
    users = [user].compact
    if !user && params['key'] && params['key'].match(/@/)
      users = User.where(:email_hash => User.generate_email_hash(params['key'].strip))
    end
    not_disabled_users = users.select{|u| !u.settings['email_disabled'] }
    reset_users = not_disabled_users.select{|u| u.generate_password_reset }
    if users.length > 0
      if reset_users.length > 0
        UserMailer.schedule_delivery(:forgot_password, reset_users.map(&:global_id))
        if reset_users.length == users.length
          render json: {email_sent: true, users: users.length}.to_json
        else
          message = "One or more of the users matching that name or email have had too many password resets, so those links weren't emailed to you. Please wait at least three hours and try again."
          render json: {email_sent: true, users: users.length, message: message}.to_json
        end
      else
        message = "All users matching that name or email have had too many password resets. Please wait at least three hours and try again."
        message = "The user matching that name or email has had too many password resets. Please wait at least three hours and try again." if users.length == 1
        message = "The email address for that account has been manually disabled." if not_disabled_users.length == 0
        api_error 400, {email_sent: false, users: 0, error: message, message: message}
      end
    else
      if params['key'] && params['key'].match(/@/) && users.present?
        UserMailer.schedule_delivery(:login_no_user, params['key'])
        render json: {email_sent: true, users: 0}.to_json
      else
        message = "No users found with that name or email."
        api_error 400, {email_sent: false, users: 0, error: message, message: message}
      end
    end
  end
  
  def password_reset
    user = User.find_by_path(params['user_id'])
    if user && reset_token = user.reset_token_for_code(params['code'])
      render json: {valid: true, reset_token: reset_token}.to_json
    else
      api_error 400, {valid: false}
    end
  end
  
  def core_lists
    res = {defaults: WordData.core_lists, fringe: WordData.fringe_lists}
    if params['user_id'] != 'none'
      user = User.find_by_path(params['user_id'])
      return unless exists?(user, params['user_id'])
      return unless allowed?(user, 'model')
      # TODO: move this to a progress call and return 
      # an auto-deleting download link
      res.merge!(WordData.core_and_fringe_for(user))
    end
    render json: res
  end
  
  def update_core_list
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'edit')
    template = UserIntegration.find_by(:template => true, :integration_key => 'core_word_list')
    if !template
      return api_error 400, {error: 'no core word list integration defined'}
    end
    
    ui = UserIntegration.find_or_create_by(:template_integration => template, :user => user)
    ui.settings['core_word_list'] = {
      id: params['id'],
      words: params['words']
    }
    ui.save
    render json: {updated: true, words: ui.settings['core_word_list']}
  end
  
  def message_bank_suggestions
    list = WordData.message_bank_suggestions
    render json: list
  end
  
  def daily_stats
    user = User.find_by_path(params['user_id'])
    return unless allowed?(user, 'supervise')
    begin
      options = request.query_parameters
      render json: Stats.cached_daily_use(user.global_id, options)
    rescue Stats::StatsError => e
      api_error 400, {error: e.message}
    end
  end
  
  def daily_use
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'admin_support_actions')
    log = LogSession.find_by(:user_id => user.id, :log_type => 'daily_use')
    if log
      render json: JsonApi::Log.as_json(log, :wrapper => true, :permissions => @api_user).to_json
    else
      api_error 400, {error: 'no data available'}
    end
  end
  
  def hourly_stats
    user = User.find_by_path(params['user_id'])
    return unless allowed?(user, 'supervise')
    begin
      options = request.query_parameters
      render json: Stats.hourly_use(user.global_id, options)
    rescue Stats::StatsError => e
      api_error 400, {error: e.message}
    end
  end

  def alerts
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'supervise')
    alerts = LogSession.where(user: user, log_type: 'note').order('id DESC').select{|s| s.data['notify_user'] && !s.alert_cleared? }
    render json: JsonApi::Alert.paginate(params, alerts)
  end

  def protected_image
    user = User.find_by_path(params['user_id'])
    api_user = User.find_by_token(params['user_token'])
    valid_result = nil
    if !api_user
      expires_in 30.minutes, :public => true
      fallback = Uploader.fallback_image_url(params['image_id'], params['library'])
      if fallback
        res = grab_url(fallback)
        send_data res.body, :type => res.headers['Content-Type'], :disposition => 'inline'
        return
      end
      return redirect_to '/images/square.svg'
    else
      users = [user, api_user].uniq
      users.each do |user|
        next if valid_result || !user
        safe_url = ButtonImage.cached_copy_url(request.original_url, user, false)
        if safe_url
          expires_in 12.days, :public => true
          return redirect_to safe_url
        end
        url = Uploader.found_image_url(params['image_id'], params['library'], user)
        if url
          url = url.sub(/^https/, 'http') if params['library'] == 'lessonpix'
          begin
            Timeout.timeout(5) do
              res = grab_url(url)
              if res.headers['Content-Type'] && res.headers['Content-Type'].match(/image/)
                valid_result = res
                expires_in 12.days, :public => true
              end
            end
          rescue Timeout::Error => e
            valid_result = nil
          end
        end
      end
    end
    if valid_result
      expires_in 24.hours, :public => true
      send_data valid_result.body, :type => valid_result.headers['Content-Type'], :disposition => 'inline'
    else
      expires_in 30.minutes, :public => true
      fallback = Uploader.fallback_image_url(params['image_id'], params['library'])
      if fallback
        res = grab_url(fallback)
        send_data res.body, :type => res.headers['Content-Type'], :disposition => 'inline'                
      else
        redirect_to '/images/error.png'
      end
    end
  end

  
  def translate
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'delete')
    res = WordData.translate_batch(params['words'].map{|w| {:text => w } }, params['source_lang'], params['destination_lang'])
    render json: res.to_json
  end
  
  def word_map
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'view_word_map')
    res = BoardDownstreamButtonSet.word_map_for(user)
    render json: res.to_json
  end

  def transfer_eval
    # TODO: throttling
    # supervisor or user may transfer the eval
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'edit')
    return allowed?(user, 'never_allow') unless user.eval_account?
    target = User.find_by_path(params['user_name'])
    if !target || !target.valid_password?(params['password'])
      return api_error(400, {error: 'invalid_credentials'})
    end
    progress = Progress.schedule(user, :transfer_eval_to, target.global_id, @api_device_id, true)
    render json: JsonApi::Progress.as_json(progress, :wrapper => true)
  end

  def reset_eval
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'edit')
    # if user has supervisors, then only the supervisor can reset the eval
    return allowed?(user, 'never_allow') if user == @api_user && !user.supervisors.blank?
    # if user has a managed org, then they can't reset their own eval
    return allowed?(user, 'never_allow') if user == @api_user && Organization.managed?(user)
    return api_error(400, {error: "not an eval account"}) unless user.eval_account?

    if !params['email'] || params['email'] == user.settings['email']
#      return api_error(400, {error: 'new email cannot match previous email'})
    end

    opts = {
      'email' => params['email'], 
      'password' => params['password'], 
      'home_board_key' => params['home_board_key'],
      'symbol_library' => params['symbol_library']
    }
    if params['expires']
      opts['expires'] = params['expires']
    end

    progress = Progress.schedule(user, :reset_eval, @api_device_id, opts)
    render json: JsonApi::Progress.as_json(progress, :wrapper => true)
  end

  def update_2fa
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'edit')
    if params['action_2fa'] == 'enable' || (params['action_2fa'] == 'reset' && (user.settings['2fa'] || user.settings['tmp_2fa']))
      user.assert_2fa!(user.global_id == @api_user.global_id)
    elsif params['action_2fa'] == 'disable'
      user.settings.delete('2fa')
      user.settings.delete('tmp_2fa')
      user.save
    elsif params['action_2fa'] == 'confirm'
      ts = user.valid_2fa?(params['code_2fa'])
      return api_error 400, {error: "invalid code: #{params['code_2fa']}"} unless ts
    else
      return api_error 400, {error: "unregognized action: #{params['action_2fa']}"}
    end
    res = {updated: true, state: user.state_2fa}
    if (user.settings || {})['tmp_2fa']
      res[:uri] = user.uri_2fa 
    end
    render json: res
  end

  def external_nonce
    nonce = ExternalNonce.find_by_global_id(params['nonce_id'])
    if params['ref_type'] == 'log_session' && params['ref_id']
      session = LogSession.find_by_global_id(params['ref_id'])
      return unless exists?(session, params['ref_id'])
      return unless allowed?(session.user, 'supervise')
    else
      nonce = nil
    end
    return unless exists?(nonce, params['nonce_id'])
    render json: nonce.encryption_result
  end
  
  protected
  def grab_url(url)
    res = Typhoeus.get(url, timeout: 3)
    if res.headers['Location']
      res = Typhoeus.get(URI.escape(res.headers['Location']), timeout: 3)
    end
    res
  end
end
