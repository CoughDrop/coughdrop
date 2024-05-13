class SessionController < ApplicationController
  before_action :require_api_token, :only => [:oauth_logout]
  
  def oauth
    error = nil
    response.headers.except! 'X-Frame-Options'
    authorized_user_id = nil
    if params['tmp_token']
      # Restoring code state after going through SAML auth process
      @access_token = RedisInit.default.get("token_tmp_#{params['tmp_token']}")
      config = JSON.parse(RedisInit.default.get("oauth_#{params['oauth_code']}")) rescue nil
      if @access_token && config
        user = config['authorized_user_id'] && User.find_by_path(config['authorized_user_id'])
        if user && user.state_2fa[:required]
          @code_plus_2fa = params['oauth_code']
        end

        @user_name = params['user_name']
        authorized_user_id = config['authorized_user_id']
        params['redirect_uri'] = config['redirect_uri']
        params['scope'] = config['scope']
        params['device_key'] = config['device_key']
        params['device_name'] = config['device_name']
        params['client_id'] = config['client_id']
      else
        error = 'resume_failed'
      end
    end
    key = DeveloperKey.find_by(:key => params['client_id'])
    if !key
      error = 'invalid_key'
    end
    if key && !key.valid_uri?(params['redirect_uri'])
      error = 'bad_redirect_uri'
    end
    @app_name = (key && key.name) || "the application"
    @app_icon = (key && key.icon_url) || "https://opensymbols.s3.amazonaws.com/libraries/arasaac/friends_3.png"
    if error
      @error = error
      render #:status => 400
    else
      scope = params['scope'] || 'read_profile'
      scope = scope.sub(/full/, '')
      config = {
        'client_id' => params['client_id'],
        'scope' => scope,
        'redirect_uri' => params['redirect_uri'] || key.redirect_uri,
        'device_key' => params['device_key'],
        'device_name' => params['device_name'],
        'authorized_user_id' => authorized_user_id,
        'app_name' => @app_name,
        'app_icon' => @app_icon
      }
      @config = config
      @scope_descriptors = scope.split(/:/).uniq.map{|s| Device::VALID_API_SCOPES[s] }.compact.join("\n")
      @scope_descriptors = "no permissions requested" if @scope_descriptors.blank?
      
      @code = GoSecure.nonce('oauth_code')
      Permissions.setex(RedisInit.default, "oauth_#{@code}", 1.hour.to_i, config.to_json, true)
      # render login page
      render
    end
  end
  
  def oauth_login
    error = nil
    user = nil
    authorized_user = nil
    response.headers.except! 'X-Frame-Options'
    config = JSON.parse(RedisInit.default.get("oauth_#{params['code']}")) rescue nil
    if !config
      error = 'code_not_found'
    else
      paramified_redirect = config['redirect_uri'] + (config['redirect_uri'].match(/\?/) ? '&' : '?')
      if params['reject']
        if config['redirect_uri'] == DeveloperKey.oob_uri
          redirect_to oauth_local_url(:error => 'access_denied')
        else
          redirect_to paramified_redirect + "error=access_denied"
        end
        return
      end
      authorized_user = User.find_by_path(config['authorized_user_id']) if config['authorized_user_id'] && params['resume']
      user = authorized_user
      if !user
        auth_org = Organization.external_auth_for(params['username'])
        if auth_org
          # SAML auth required for this user
          redirect_to "/saml/init?org_id=#{auth_org.global_id}&device_id=saml_auth&embed=1&oauth_code=#{params['code']}"
          return
        end
        user = User.find_for_login(params['username'], (@domain_overrides || {})['org_id'], params['password'])

        if user && user.valet_mode?
          error = 'invalid_login'
        elsif user && params['approve_token']
          id = params['approve_token'].split(/~/)[0]
          device = Device.find_by_global_id(id)
          if !device || !device.valid_token?(params['approve_token']) || !device.permission_scopes.include?('full')
            error = 'invalid_token'
          end
        elsif !user || !user.valid_password?(params['password'])
          error = 'invalid_login'
        end
      end
    end
    if params['2fa_code']
      if user.valid_2fa?(params['2fa_code'])
        @valid_2fa = true
        config['approved_2fa'] = true
      else
        @code_plus_2fa = params['code']
        @invalid_2fa = true
        @app_name = (config && config['app_name']) || 'the application'
        @app_icon = (config && config['app_icon']) || "https://opensymbols.s3.amazonaws.com/libraries/arasaac/friends_3.png"
        @scope_descriptors = (config['scope'] || '').split(/:/).uniq.map{|s| Device::VALID_API_SCOPES[s] }.compact.join("\n")
        @scope_descriptors = "no permissions requested" if @scope_descriptors.blank?
        render :oauth, :status => 400
        return
      end
    end
    if error
      config ||= {}
      @app_name = (config && config['app_name']) || 'the application'
      @app_icon = (config && config['app_icon']) || "https://opensymbols.s3.amazonaws.com/libraries/arasaac/friends_3.png"
      @scope_descriptors = (config['scope'] || '').split(/:/).uniq.map{|s| Device::VALID_API_SCOPES[s] }.compact.join("\n")
      @scope_descriptors = "no permissions requested" if @scope_descriptors.blank?
      @code = params['code']
      @error = error
      render :oauth, :status => 400
    else
      do_render = false
      if !@valid_2fa && user.state_2fa[:required]
        # If the user is authenticated but missing 2fa, show the prompt
        config['authorized_user_id'] = user.global_id
        @code_plus_2fa = params['code']
        do_render = true
      end
      if !params['resume']
        user.password_used!
      end
      config['user_id'] = user.id.to_s
      Permissions.setex(RedisInit.default, "oauth_#{params['code']}", 1.hour.to_i, config.to_json, true)
      if do_render
        @app_name = (config && config['app_name']) || 'the application'
        @app_icon = (config && config['app_icon']) || "https://opensymbols.s3.amazonaws.com/libraries/arasaac/friends_3.png"
        @scope_descriptors = (config['scope'] || '').split(/:/).uniq.map{|s| Device::VALID_API_SCOPES[s] }.compact.join("\n")
        @scope_descriptors = "no permissions requested" if @scope_descriptors.blank?
        render :oauth
      elsif config['redirect_uri'] == DeveloperKey.oob_uri
        redirect_to oauth_local_url(:code => params['code'])
      else
        redirect_to paramified_redirect + "code=#{params['code']}"
      end
    end
  end
  
  def oauth_token
    key = DeveloperKey.find_by(:key => params['client_id'])
    error = nil
    if !key
      error = 'invalid_key'
    elsif key.secret != params['client_secret']
      error = 'invalid_secret'
    end
    
    config = JSON.parse(RedisInit.default.get("oauth_#{params['code']}")) rescue nil
    if !error
      if !config
        error = 'code_not_found'
      elsif !config['user_id']
        error = 'token_not_ready'
      end
    end
    
    if error
      api_error 400, {error: error}
    else
      RedisInit.default.del("oauth_#{params['code']}")
      device = Device.find_or_create_by(:user_id => config['user_id'], :developer_key_id => key.id, :device_key => config['device_key'])
      device.settings['name'] = config['device_name']
      device.settings['name'] += device.id.to_s if device.settings['name'] == 'browser'
      device.settings['name'] ||= (key.name || "Token") + " account"
      device.settings['permission_scopes'] = []
      (config['scope'] || '').split(/:/).uniq.each do |scope|
        device.settings['permission_scopes'].push(scope) if Device::VALID_API_SCOPES[scope]
      end
      device.generate_token!
      if device.settings['2fa'] && device.settings['2fa']['pending']
        if config['approved_2fa']
          device.confirm_2fa!(:approve, true)
        end
      end
      render json: JsonApi::Token.as_json(device.user, device, :include_refresh => true).to_json
    end
  end
  
  def oauth_logout
    Device.find_by_global_id(@api_device_id).logout!
    render json: {logout: true}.to_json
  end
  
  def oauth_local
    response.headers.except! 'X-Frame-Options'
  end

  def oauth_token_refresh
    device = Device.find_by_global_id(@api_device_id)

    key = DeveloperKey.find_by(:key => params['client_id'])
    error = nil
    if !key
      error = 'invalid_key'
    elsif key.secret != params['client_secret']
      error = 'invalid_secret'
    elsif !device || device.developer_key_id != key.id
      error = 'invalid_token'
    end

    if error
      api_error 400, {error: error}
    elsif @api_user && device && device.token_type == :integration
      token, refresh_token = device.generate_from_refresh_token!(params['access_token'], params['refresh_token'])
      if token
        render json: JsonApi::Token.as_json(@api_user, device, :include_refresh => true).to_json
      else
        api_error 400, { error: "Invalid refresh token" }
      end
    else
      api_error 400, { error: "Could not find refresh token"}
    end
  end

  def auth_admin
    success = false
    if @api_user && @api_user.admin?
      admin_token = GoSecure.nonce('admin_token')
      cookies[:admin_token] = admin_token
      Permissions.setex(Permissable.permissions_redis, '/admin/auth/' + admin_token, 2.hours.to_i, @api_user.global_id, true)
      success = true
    end
    render json: {success: success}
  end

  def saml_metadata
    org = Organization.find_by_global_id(params['org_id']) if params['org_id']
    return render inline: "Error: no org specified" unless org
    return render inline: "Error: org not configured" unless org.settings['saml_metadata_url']
    settings = saml_settings(org)
    meta = OneLogin::RubySaml::Metadata.new
    xml = Nokogiri(meta.generate(settings))
    elem = xml.css('md|SPSSODescriptor')[0]
    root = xml.css('md|EntityDescriptor')[0]
    if elem && root
      root.add_namespace('mdui', "urn:oasis:names:tc:SAML:metadata:ui")
      ext = Nokogiri::XML::Node.new('md:Extensions', xml)
      uiinf = Nokogiri::XML::Node.new('mdui:UIInfo', xml)
      dn = Nokogiri::XML::Node.new('mdui:DisplayName', xml)
      dn['xml:lang'] = 'en'
      dn.content = "CoughDrop"
      desc = Nokogiri::XML::Node.new('mdui:Description', xml)
      desc['xml:lang'] = 'en'
      desc.content = "CoughDrop AAC Application"
      logo = Nokogiri::XML::Node.new('mdui:Logo', xml)
      logo['xml:lang'] = 'en'
      logo['width'] = '64'
      logo['height'] = '64'
      logo.content = "#{request.protocol}#{request.host_with_port}/images/logo.png"
      uiinf << dn
      uiinf << desc
      uiinf << logo
      ext << uiinf
      elem.prepend_child(ext)
    end
    render :xml => xml.to_s, :content_type => "application/samlmetadata+xml"
  end

  def auth_lookup
    org = Organization.find_by_saml_issuer(params['ref'])
    org ||= Organization.find_by_global_id(params['ref'])
    if !org
      user = User.find_by_path(params['ref']) 
      user ||= User.find_by_email(params['ref'])[0]
      org = Organization.external_auth_for(user, true) if user
    end
    if org && org.settings['saml_metadata_url']
      url = "#{request.protocol}#{request.host_with_port}/saml/init?org_id=#{org.global_id}&device_id=#{params['device_id'] || 'saml_auth'}"
      if params['user_id']
        user = User.find_by_path(params['user_id'])
        return unless exists?(user, params['user_id'])
        return unless allowed?(user, 'link_auth')
        nonce = GoSecure.nonce('saml_tmp_token')
        Permissions.setex(RedisInit.default, "token_tmp_#{nonce}", 15.minutes.to_i, @token, true)
        url += "&user_id=#{user.global_id}&tmp_token=#{nonce}"
      end
      render json: {url: url}
    else
      api_error 400, {error: "no result found", ref: params['ref']}
    end
  end

  def saml_tmp_token
    if !@token
      return api_error 400, {error: 'no token available'}
    end
    nonce = GoSecure.nonce('saml_tmp_token')
    Permissions.setex(RedisInit.default, "token_tmp_#{nonce}", 15.minutes.to_i, @token, true)
    render json: {tmp_token: nonce}
  end

  def saml_redirect
    org = Organization.find_by_global_id(params['org_id'])
    if !org || !org.settings['saml_metadata_url']
    end
    render
  end

  def saml_start
    org = Organization.find_by_global_id(params['org_id'])
    return render inline: "Org missing" unless org
    return render inline: "Org not set up for external auth" unless org.settings['saml_metadata_url']

    return_params = {}
    if params['user_id']
      user = User.find_by_path(params['user_id'])
      if @api_user && user && user.allows?(@api_user, 'link_auth')
        return_params['user_id'] = user.global_id
        return_params['auth_user_id'] = @api_user.global_id
      else
        return render inline: "Could not connect external login to user account"
      end
    else
    end
    return_params['oauth_code'] = params['oauth_code'] if params['oauth_code']
    return_params['device_id'] = params['device_id'] || 'unnamed device'
    return_params['app'] = true if params['app']
    return_params['embed'] = true if params['embed']
    return_params['popout_id'] = params['popout_id'] if params['popout_id']

    code = GoSecure.nonce('saml_session_code')

    return_params['org_id'] = org.global_id
    Permissions.setex(RedisInit.default, "saml_#{code}", 1.hour.to_i, return_params.to_json, true)
    @saml_code = code

    request = OneLogin::RubySaml::Authrequest.new
    settings = saml_settings(org, code)
    redirect_to(request.create(settings, :RelayState => code))
  end

  def saml_consume
    @error = nil
    code = params['code'] || params['RelayState']
    config = JSON.parse(RedisInit.default.get("saml_#{code}")) rescue nil
    if !config
      @error = code ? "Auth session lost" : "Missing auth session code"
      return render
    end
    org = Organization.find_by_global_id(config['org_id'])
    if !org
      @error = "Provider not found in the system" 
      return render
    end
    response = OneLogin::RubySaml::Response.new(params[:SAMLResponse], :settings => saml_settings(org, code))
    authenticated_user = nil
    if !response.is_valid?
      @error = "Authenticator signature failed"
      return render
    end

    email = response.attributes.fetch('email') || response.attributes['urn:oid:0.9.2342.19200300.100.1.3'] || response.attributes['urn:mace:dir:attribute-def:mail']
    user_name = response.attributes.fetch('uid') || response.attributes['urn:oid:0.9.2342.19200300.100.1.1'] || response.attributes['urn:mace:dir:attribute-def:uid']
    data = {external_id: response.name_id, issuer: response.issuers[0], email: email, user_name: user_name, roles: response.attributes.multi(:role)}
    if org != Organization.find_by_saml_issuer(data[:issuer])
      @error = "Org mismatch"
      return render
    end
    if config['user_id']
      # link the user to the external authentication
      auth_user = User.find_by_global_id(config['auth_user_id'])
      existing_user = User.find_by_global_id(config['user_id']) 
      if !existing_user || !existing_user.allows?(auth_user, 'link_auth')
        @error = "Mismatched user connection" 
        return render
      end
      org.link_saml_user(existing_user, data)
      authenticated_user = existing_user
    else
      authenticated_user = org.find_saml_user(data[:external_id], email)
      if !authenticated_user
        # If user isn't already connected, see if you can auto-connect by user name or email
        attached = org.attached_users('all')
        fallback_user = org.find_saml_alias(data[:user_name], data[:email])
        fallback_user ||= attached.find_by(user_name: user_name)
        if !fallback_user
          emails = attached.where(email_hash: User.generate_email_hash(data[:email]))
          fallback_user = emails[0] if emails.count == 1
        end
        if fallback_user
          org.link_saml_user(fallback_user, data)
          authenticated_user = fallback_user
        end
      end
      if !authenticated_user
        @error = "User not found in the system, please have your account admin connect your accounts (#{data[:user_name]})" 
        return render
      end
    end
    # We validate the SAML Response and check if the user already exists in the system
    if response.is_valid? && authenticated_user
      RedisInit.default.del("saml_#{code}")
      device = Device.find_or_create_by(:user_id => authenticated_user.id, :developer_key_id => 0, :device_key => config['device_id'] || 'unnamed device')
      if config['oauth_code']
        # Redirect back to authorization for oauth flow
        RedisInit.default.del("saml_#{config['oauth_code']}")
        device.settings['auth_device'] = true
        device.save
        token = device.generate_token!(false)
        nonce = GoSecure.nonce('oauth_access_token')
        @temp_token = nonce
        Permissions.setex(RedisInit.default, "token_tmp_#{nonce}", 15.minutes.to_i, token, true)
        redirect_to oauth2_token_url(tmp_token: nonce, user_name: authenticated_user.user_name, oauth_code: config['oauth_code'])
      elsif config['embed']
        # For embed flow, show success and post it to the parent window
        device.settings['used_for_saml'] = true
        assert_session_device(device, authenticated_user, config['app'])
        @saml_data = data
        @authenticated_user = authenticated_user
        render
      elsif config['popout_id']
        # For popout flow, where a browser window opens to perform the auth,
        # show a success message and direct the user to return to the app
        device.settings['used_for_saml'] = true
        Permissions.setex(RedisInit.default, "token_popout_#{config['popout_id']}", 30.minutes.to_i, {user_id: authenticated_user.global_id, device_id: device.global_id}.to_json, true)
        assert_session_device(device, authenticated_user, config['app'])
        @saml_data = data
        @authenticated_user = authenticated_user
        @no_parent = true
        render
      elsif config['user_id']
        # For connection flow, redirect back to the user's profile page, all is done
        redirect_to "/#{authenticated_user.user_name}"
      else
        device.settings['used_for_saml'] = true
        # For standard flow, redirect to login page with temporary auth token
        nonce = GoSecure.nonce('saml_tmp_token')
        assert_session_device(device, authenticated_user, config['app'])
        access, refresh = device.tokens
        @temp_token = nonce
        Permissions.setex(RedisInit.default, "token_tmp_#{nonce}", 15.minutes.to_i, access, true)
        redirect_to "/login?auth-#{nonce}_#{authenticated_user.user_name}"
      end
    else
      @error = authenticated_user ? "Invalid authentication" : "No user found"
      return render
    end    
  end

  # Method to handle IdP initiated logouts
  def saml_idp_logout_request
    logout_request = OneLogin::RubySaml::SloLogoutrequest.new(params[:SAMLRequest])
    if !logout_request.is_valid?
      logger.error "IdP initiated LogoutRequest was not valid!"
      return render :inline => "Error: Invalid logout request"
    end
    org = Organization.find_by_saml_issuer(logout_request.issuer)
    return render inline: "No valid org found for issuer" unless org
    settings = saml_settings(org)
    logger.info "IdP initiated Logout for #{logout_request.name_id}"

    # Actually log out this session
    user = org.find_saml_user(logout_request.name_id)
    if user
      user.devices.each{|d| d.invalidate_keys! if d.settings['used_for_saml'] }
    end

    # Generate a response to the IdP.
    logout_request_id = logout_request.id
    logout_response = OneLogin::RubySaml::SloLogoutresponse.new.create(settings, logout_request_id, nil, :RelayState => params[:RelayState])
    redirect_to logout_response
  end

  def token_wait
    if params['popout_id']
      json = RedisInit.default.get("token_popout_#{params['popout_id']}")
      auth = JSON.parse(json) rescue nil
      user = auth && User.find_by_global_id(auth['user_id'])
      device = auth && Device.find_by_global_id(auth['device_id'])
      if user && device && user == device.user
        RedisInit.default.del("token_popout_#{params['popout_id']}")
        render json: JsonApi::Token.as_json(user, device).to_json
      else
        return render json: {error: 'not found'}
      end
    else
      api_error 400, {error: 'popout_id required'}
    end
  end

  def token
    set_browser_token_header
    if params['grant_type'] == 'password'
      pending_u = User.find_for_login(params['username'], (@domain_overrides || {})['org_id'], params['password'], true)

      if pending_u.present? && !pending_u.activated
        return api_error(400, {error: 'User is deactivated'})
      end

      auth_org = Organization.external_auth_for(params['username'])
      if auth_org
        return render json: {auth_redirect: "#{request.protocol}#{request.host_with_port}/saml/init?org_id=#{auth_org.global_id}&device_id=#{params['device_id']}"}
      end
      u = nil
      if params['client_id'] == 'browser' && GoSecure.valid_browser_token?(params['client_secret'])
        u = pending_u
      else
        return api_error 400, { error: "Invalid client_secret for client_id", client_id: params['client_id'] }
      end
      if u && u.valid_password?(params['password'])
        # generated based on request headers
        device_key = request.headers['X-Device-Id'] || params['device_id'] || 'default'
        
        installed_app = request.headers['X-INSTALLED-COUGHDROP'] == 'true' || params['installed_app'] == 'true'
        d = Device.find_or_create_by(:user_id => u.id, :developer_key_id => 0, :device_key => device_key)
        assert_session_device(d, u, installed_app)

        u.password_used!
        render json: JsonApi::Token.as_json(u, d).to_json
      else
        old_key = nil
        begin
          old_key = OldKey.find_by(:type => 'user', :key => params['username'])
        rescue ActiveRecord::StatementInvalid => e
          ActiveRecord::Base.connection.verify!
          old_key = OldKey.find_by(:type => 'user', :key => params['username'])
        end

        user = old_key && old_key.record
        if user && user.valid_password?(params['password'])
          api_error 400, { error: "User name was changed", user_name: user.user_name}
        else
          api_error 400, { error: "Invalid authentication attempt" }
        end
      end
    else
      api_error 400, { error: "Invalid authentication approach" }
    end
  end
  
  def token_check
    set_browser_token_header
    if @api_user
      params['access_token'] = @token if @token && @tmp_token
      device = Device.find_by_global_id(@api_device_id)
      valid = device && device.valid_token?(params['access_token'], request.headers['X-CoughDrop-Version'])
      expired = device && (device.instance_variable_get('@expired_keys') || {})[params['access_token']]
      needs_refresh = device && (device.instance_variable_get('@refreshable_keys') || {})[params['access_token']]
      json = {
        authenticated: valid, 
        expired: !!(expired || needs_refresh),
        user_name: @api_user.user_name, 
        user_id: @api_user.global_id,
        device_id: @api_device_id,
        modeling_session: @api_user.valet_mode?,
        avatar_image_url: (valid ? @api_user.generated_avatar_url : nil),
        scopes: device && device.permission_scopes,
        sale: Purchasing.current_sale,
        ws_url: ENV['CDWEBSOCKET_URL'],
        global_integrations: UserIntegration.global_integrations.keys,
      }
      if params['2fa_code']
        json['valid_2fa'] = !!device.confirm_2fa!(params['2fa_code'])
        json[:scopes] = device.permission_scopes
        json['cooldown_2fa'] = device.settings['2fa']['cooldown'] if (device.settings['2fa'] || {})['cooldown']
      end
      if params['include_token']
        json[:token] = JsonApi::Token.as_json(@api_user, device)
      end
      json[:can_refresh] = true if needs_refresh && !expired
      render json: json.to_json
    else
      render json: {
        authenticated: false, 
        sale: Purchasing.current_sale,
        ws_url: ENV['CDWEBSOCKET_URL'],
        global_integrations: UserIntegration.global_integrations.keys
      }.to_json
    end
  end

  def heartbeat
    render json: {active: true}
  end

  def status
    last_id = (Board.last || OpenStruct.new(id: 5)).id
    Board.find_by(id: rand(last_id))
    user_id = (User.last || OpenStruct.new(id: 9)).id
    LogSession.where(user_id: user_id).count
    ids = Board.where(public: true).limit(10).map(&:global_id)
    RedisInit.default.incr('status_checks')
    RedisInit.default.del('status_checks') if RedisInit.default.get('status_checks').to_i > 50000
    RedisInit.default.get('trends_tracked_recently')
    if ENV['QUEUE_MAX']
      ['slow', 'default', 'priority'].each do |q|
        if Resque.redis.llen("queue:#{q}") > ENV['QUEUE_MAX'].to_i * 2
          render json: {danger: true, reason: 'queue'}
          return
        end
      end
    end
    render json: {active: true}
  end

  protected
  def assert_session_device(d, u, installed_app)
    store_user_data = (u.settings['preferences'] || {})['cookies'] != false
    d.settings['ip_address'] = store_user_data ? request.remote_ip : nil
    d.settings['user_agent'] = store_user_data ? request.headers['User-Agent'] : nil
    d.settings['system'] ||= params['system']
    d.settings['system_version'] ||= params['system_version']
    d.settings['mobile'] = params['mobile'] == 'true' if params['mobile'] != nil
    d.settings['browser'] = true if request.headers['X-INSTALLED-COUGHDROP'] == 'false'
    long_token = params['long_token'] && params['long_token'] != 'false'
    if installed_app
      long_token = true
      app_devices = Device.where(user_id: u.id, developer_key_id: 0).select{|d| d.token_type == :app && !d.settings['temporary_device'] }
      if app_devices.length > 0 && u.eval_account?
        # Eval accounts are only allowed to log in on one device at a time.
        # If they log into a new device. prompt them to see if they want to
        # auto-log-out on the other device, or cancel this login.
        temporary_device = true
      end
    end

    d.settings['temporary_device'] = true if temporary_device
    d.settings.delete('temporary_device') unless u.eval_account?
    d.settings.delete('temporary_device') if u.valet_mode?
    d.settings.delete('auth_device')
    d.settings['valet'] = !!u.valet_mode?
    d.settings['valet_long_term'] = !!(u.valet_mode? && u.settings['valet_long_term'])
    d.settings['app'] = true if installed_app
    if u.valet_mode? && !u.settings['valet_long_term']
      long_token = false
    end
    d.generate_token!(long_token)
  end

  def saml_settings(org=nil, code=nil)
    settings = OneLogin::RubySaml::Settings.new
  
    if org
      idp_metadata_parser = OneLogin::RubySaml::IdpMetadataParser.new
      # Returns OneLogin::RubySaml::Settings prepopulated with idp metadata
      settings = idp_metadata_parser.parse_remote(org.settings['saml_metadata_url'], {
        :sso_binding => ['urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect'],
        :slo_binding => ['urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect']
      })
      # settings.idp_entity_id                  = "https://app.onelogin.com/saml/metadata/#{OneLoginAppId}"
      # settings.idp_sso_service_url             = "https://app.onelogin.com/trust/saml2/http-post/sso/#{OneLoginAppId}"
      # settings.idp_slo_service_url             = "https://app.onelogin.com/trust/saml2/http-redirect/slo/#{OneLoginAppId}"
      # settings.idp_cert_fingerprint           = OneLoginAppCertFingerPrint
      # settings.idp_cert_fingerprint_algorithm = "http://www.w3.org/2000/09/xmldsig#sha1"
      # settings.name_identifier_format         = "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"
      settings.idp_sso_service_url = org.settings['saml_sso_url'] if org.settings['saml_sso_url']
    end
  
    url = "#{request.protocol}#{request.host_with_port}/saml/consume"
    url += "?org_id=#{org.global_id}" if org
    # url += (url.match(/\?/) ? '&' : '?') + "code=#{code}" if code
    settings.assertion_consumer_service_url = url
    meta_url = "#{request.protocol}#{request.host_with_port}/saml/metadata"
    meta_url += "?org_id=#{org.global_id}" if org
    settings.issuer = meta_url
    settings.sp_entity_id                   = meta_url
    # settings.logo = "http"

    # Optional for most SAML IdPs
    # settings.authn_context = "urn:oasis:names:tc:SAML:2.0:ac:classes:PasswordProtectedTransport"
    # or as an array
    # settings.authn_context = [
    #   "urn:oasis:names:tc:SAML:2.0:ac:classes:PasswordProtectedTransport",
    #   "urn:oasis:names:tc:SAML:2.0:ac:classes:Password"
    # ]
  
    # Optional bindings (defaults to Redirect for logout POST for acs)
    settings.single_logout_service_binding      = "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect"
    settings.assertion_consumer_service_binding = "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
  
    settings
  end
end
