module Passwords
  extend ActiveSupport::Concern
  
  def generate_password_reset
    clean_password_resets
    if self.settings['password_resets'].length > 5
      Rails.logger.warn("Throttled password reset for user \"#{self.user_name}\", too many attempts")
      return false 
    end
    self.settings['password_resets'] << {
      'timestamp' => Time.now.to_i,
      'code' => GoSecure.nonce('password_reset_code')
    }
    self.save
  end
  
  def password_reset_code
    clean_password_resets
    reset = self.settings['password_resets'][-1]
    reset && reset['code']
  end
  
  def reset_token_for_code(code)
    clean_password_resets
    reset = self.settings['password_resets'].detect{|r| r['code'] == code }
    return nil unless reset
    
    reset['token'] = GoSecure.nonce('password_reset_token')
    self.save
    reset['token']
  end
  
  def valid_reset_token?(token)
    clean_password_resets
    !!self.settings['password_resets'].detect{|r| r['token'] == token }
  end
  
  def used_reset_token!(token)
    clean_password_resets
    self.settings['password_resets'] = self.settings['password_resets'].select{|r| r['token'] != token }
    self.save
  end
  
  def clean_password_resets
    self.settings ||= {}
    now = Time.now.to_i
    self.settings['password_resets'] ||= []
    self.settings['password_resets'].select!{|r| r['timestamp'] > now - (60 * 60 * 3) }
  end
  
  def assert_2fa!(temp=false)
    if temp
      self.settings['tmp_2fa'] = {
        'secret' => self.random_2fa,
        'expires' => 6.hours.from_now.to_i
      }
    else
      self.settings['2fa'] = {
        'secret' => self.random_2fa
      }
      self.settings.delete('tmp_2fa')
    end
    self.save!
  end

  def random_2fa
    ROTP::Base32.random
  end

  def state_2fa
    state = {}
    state[:required] = !!self.settings['2fa']
    if ((self.settings['tmp_2fa'] || {})['expires'] || 0) < Time.now.to_i
      if self.settings['tmp_2fa']
        self.settings.delete('tmp_2fa')
        self.save
      end
    end
    if Organization.admin_manager?(self)
      state[:required] = true
      state[:mandatory] = true
      self.assert_2fa! if !self.settings['2fa'] && !self.settings['tmp_2fa']
    end
    if state[:required]
      state[:verified] = !!(self.settings['2fa'] || {})['last_otp']
    end
    state
  end

  def uri_2fa
    secret = ((self.settings || {})['tmp_2fa'] || {})['secret']
    secret ||= ((self.settings || {})['2fa'] || {})['secret']
    return nil unless secret
    totp = ROTP::TOTP.new(secret, issuer: "CoughDrop")  
    totp.provisioning_uri(self.user_name).sub(/\?/, ':?')
  end

  def valid_2fa?(code)
    valid_type = nil
    secret = ((self.settings || {})['2fa'] || {})['secret']
    tmp_secret = ((self.settings || {})['tmp_2fa'] || {})['secret']
    return false unless secret || tmp_secret
    ts = nil
    if secret
      totp = ROTP::TOTP.new(secret, issuer: "CoughDrop")  
      now = Time.now.to_i
      totp.at(now)
      ts = totp.verify(code, drift_behind: 15)
      valid_type = :default if ts
    end
    if tmp_secret && !ts
      totp = ROTP::TOTP.new(tmp_secret, issuer: "CoughDrop")  
      now = Time.now.to_i
      totp.at(now)
      ts = totp.verify(code, drift_behind: 15)
      valid_type = :temp if ts
    end
    last_otp = ((self.settings || {})['2fa'] || {})['last_otp'] || 0
    if ts && valid_type == :temp
      self.settings.delete('tmp_2fa')
      self.settings['2fa'] = {
        'secret' => tmp_secret,
        'last_otp' => ts
      }
      self.save
    elsif ts && ts > last_otp
      self.settings.delete('tmp_2fa')
      self.settings['2fa']['last_otp'] = ts
      self.save
      ts
    else
      false
    end
  end

  def valet_mode?
    !!@valet_mode
  end

  def valet_allowed?
    # If the valet password has been triggered and not re-activated
    # more than 24 hours ago, then its use is not allowed. When
    # the valet password has been triggered and the regular password
    # is subsequently used, the valet password should be de-activated.
    return false if !self.settings || self.settings['valet_password_disabled']
    return false if (self.settings['valet_password_at'] && self.settings['valet_password_at'] < 24.hours.ago.to_i) && !self.settings['valet_prevent_disable']
    return false unless self.settings['valet_password']
    return true
  end

  def valet_temp_password(nonce)
    return nil unless self.settings && self.settings['valet_password']
    sig = self.settings['valet_password']['hashed_password']
    "#{nonce}?:##{GoSecure.sha512(sig, nonce)[0, 30]}"
  end

  def set_valet_password(password)
    hashed_password = password
    if self.settings && self.settings['valet_password'] && self.settings['valet_password']['pre_hash_algorithm']
      hashed_password = pre_hashed_password(password)
    end
    password_enabled = false
    no_prior_password = self.settings['valet_password'] == nil
    if self.valet_allowed? && self.settings['valet_password'] && GoSecure.matches_password?(hashed_password, self.settings['valet_password'])
      # Setting to the same password as already in-place, don't need to re-generate
      password_enabled = true
    elsif password == false
      self.settings.delete('valet_password')
    else
      password = GoSecure.nonce('valet_temporary_password')[0, 10] if password.blank?
      password_enabled = true
      if password
        generate_valet_password(password)
      end
    end
    if password_enabled
      self.assert_valet_mode!
      # Notify the user that the valet login has been enabled or re-enabled
      self.settings['valet_password_disabled_since'] = [self.settings['valet_password_disabled'], self.settings['valet_password_at'], 0].compact.max
      UserMailer.schedule_delivery(:valet_password_enabled, self.global_id) if self.settings['valet_password_disabled'] || self.settings['valet_password_at'] || no_prior_password
    end
    self.settings.delete('valet_password_at')
    self.settings.delete('valet_password_disabled')
  end
  
  def valet_password_used!
    # Record the valet password as having been triggered.
    do_notify = !self.settings['valet_password_at'] || self.settings['valet_password_at'] < 30.minutes.ago.to_i
    self.settings['valet_password_at'] = nil if (self.settings['valet_prevent_disable'] && self.settings['valet_password_at']  && self.settings['valet_password_at'] < 30.minutes.ago.to_i)
    self.settings['valet_password_at'] ||= Time.now.to_i
    self.save!
    # Notify user that the valet password was used
    UserMailer.schedule_delivery(:valet_password_used, self.global_id) if do_notify
  end

  def password_used!
    # If the valet password has been triggered, mark it as
    # disabled until the user re-activates it. Also clear
    # the record of the valet password being triggered.
    if self.settings['valet_password_at'] && !self.valet_mode? && !self.settings['valet_prevent_disable']
      self.settings.delete('valet_password_at')
      self.settings['valet_password_disabled'] = Time.now.to_i
      self.save!
    else
      true
    end
  end

  def assert_valet_mode!(mode=true)
    @valet_mode = mode
  end

  def valid_password?(guess)
    Rails.logger.warn("ACTION PASSWORD VALID_PASSWORD------------------------GUESS: #{guess}")

    self.settings ||= {}
    guess ||= ''
    res = false
    if self.valet_mode?
      hashed_guess = guess
      Rails.logger.warn("ACTION PASSWORD VALID_PASSWORD if condition------------------------hashed_guess: #{hashed_guess}")

      if self.settings['valet_password'] && self.settings['valet_password']['pre_hash_algorithm'] && !guess.match(/^hashed\?:\#/)
        hashed_guess = pre_hashed_password(hashed_guess)
        Rails.logger.warn("ACTION PASSWORD VALID_PASSWORD if condition------------------------hashed_guess: #{hashed_guess}")

      end
      Rails.logger.warn("ACTION PASSWORD VALID_PASSWORD if condition------------------------GoSecure.matches_password?: #{GoSecure.matches_password?(hashed_guess, self.settings['valet_password'])}")
      res = self.valet_allowed? && GoSecure.matches_password?(hashed_guess, self.settings['valet_password'])
      Rails.logger.warn("ACTION PASSWORD VALID_PASSWORD if condition------------------------res: #{res}")

      if res && !hashed_guess.match(/^hashed\?:\#/)
        hashed = pre_hashed_password(hashed_guess)
        self.generate_valet_password(hashed)
        Rails.logger.warn("ACTION PASSWORD VALID_PASSWORD if hashed_guess condition------------------------self.generate_valet_password(hashed): #{self.generate_valet_password(hashed)}")

        self.save
      elsif res && GoSecure.outdated_password?(self.settings['valet_password'])
        self.generate_valet_password(hashed_guess)
        Rails.logger.warn("ACTION PASSWORD VALID_PASSWORD if Gosecure condition------------------------self.generate_valet_password(hashed): #{self.generate_valet_password(hashed_guess)}")

        self.save
      elsif guess.match(/\?:\#/)
        nonce, hash = guess.split(/\?:\#/, 2)
        Rails.logger.warn("ACTION PASSWORD VALID_PASSWORD if Gosecure condition------------------------nonce, hash, self.valet_temp_password(nonce): #{nonce}, #{hash}, #{self.valet_temp_password(nonce)}")

        res = true if guess == self.valet_temp_password(nonce)
      end
      Rails.logger.warn("ACTION PASSWORD VALID_PASSWORD if Gosecure condition------------------------self.valet_password_used!, res: #{self.valet_password_used!}, #{res}")
      self.valet_password_used! if res
    else
      if self.settings['password'] && self.settings['password']['pre_hash_algorithm'] && !guess.match(/^hashed\?:\#/)
        guess = pre_hashed_password(guess)
        Rails.logger.warn("ACTION PASSWORD VALID_PASSWORD else condition------------------------GUESS: #{guess}")

      end
        res = GoSecure.matches_password?(guess, self.settings['password'])
        Rails.logger.warn("ACTION PASSWORD VALID_PASSWORD else condition------------------------res: #{res}")
      if res && self.schedule_deletion_at
        # prevent auto-deletion whenever a user logs in
        self.schedule_deletion_at = nil
        self.save
      end
      if res && !guess.match(/^hashed\?:\#/)
        hashed = pre_hashed_password(guess)
        self.generate_password(hashed)
        Rails.logger.warn("ACTION PASSWORD VALID_PASSWORD res && !guess.match------------------------self.generate_password(hashed): #{self.generate_password(hashed)}")
        self.save
      elsif res && GoSecure.outdated_password?(self.settings['password'])
        self.generate_password(guess)
        Rails.logger.warn("ACTION PASSWORD VALID_PASSWORD res && GoSecure.outdated_password?------------------------self.generate_password(guess): #{self.generate_password(guess)}")
        self.save
      end
    end
    Rails.logger.warn("ACTION PASSWORD VALID_PASSWORD res response------------------------res: #{res}")
    res
  end

  def pre_hashed_password(str)
    ['hashed', 'sha512', Digest::SHA512.hexdigest("cdpassword:#{str}:digested")].join("?:#")
  end

  def generate_valet_password(password)
    password = pre_hashed_password(password) if !password.match(/^hashed\?:\#/)
    self.settings ||= {}
    self.settings['valet_password'] = GoSecure.generate_password(password)
    self.settings['valet_password']['pre_hash_algorithm'] = 'sha512'
  end

  def generate_password(password)
    password = pre_hashed_password(password) if !password.match(/^hashed\?:\#/)
    self.settings ||= {}
    self.settings['password'] = GoSecure.generate_password(password)
    Rails.logger.warn("ACTION PASSWORD generate_password------------------------self.settings['password'] : #{self.settings['password']}")

    self.settings['password']['pre_hash_algorithm'] = 'sha512'
  end
end