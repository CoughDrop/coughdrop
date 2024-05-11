module ExternalTracker
  def self.track_new_user(user)
    if user && user.external_email_allowed?
      Worker.schedule(ExternalTracker, :persist_new_user, user.global_id)
    end
  end

  def self.change_user_activation(user, activation_state)
    Rails.logger.warn("ExternalTracker change_user_activation------------------------activation_state: #{activation_state}")

    Worker.schedule(ExternalTracker, :user_activation, user, activation_state)
  end

  def self.user_activation(user, activation_state)
    begin
      Rails.logger.warn("ExternalTracker user_activation------------------------user.activated: #{user.activated}")

      user.update!(activated: activation_state)
      Rails.logger.warn("ExternalTracker user_activation------------------------user.activated: #{user.activated}")

      if user.activated
        UserMailer.schedule_delivery(:user_activated, user.global_id).deliver_now
      else
        UserMailer.schedule_delivery(:user_deactivated, user.global_id).deliver_now
      end
    rescue ActiveRecord::RecordInvalid => e
      puts "Error: #{e.message}"
    end
  end

  def self.persist_new_user(user_id)
    user = User.find_by_path(user_id)
    return false unless user && user.external_email_allowed?
    return false unless ENV['HUBSPOT_TOKEN']
    return false unless user.settings && user.settings['email']

    d = user.devices[0]
    ip = d && d.settings['ip_address']
    location = nil
    if ip && ENV['IPSTACK_KEY']
      url = "http://api.ipstack.com/#{ip}?access_key=#{ENV['IPSTACK_KEY']}"
      begin
        res = Typhoeus.get(url, timeout: 5)
        location = JSON.parse(res.body)
      rescue => e
      end
    end
    email = user.settings['email']
    city = nil
    state = nil
    if location && (location['country_code'] == 'USA' || location['country_code'] == 'US')
      city = location['city']
      state = location['region_name']
    end


    acct = "Communicator Account"
    # "Supervisor Parent Account", "AT Specialist/Lending Library", "Eval"
    # "Therapist", "Teacher", "AAC Grad Course", "Org Added Supervisor", 
    # "Org added Communicator", "Supervisor other", "Communicator other"
    if user.supporter_registration?
      if user.registration_type == 'eval'
        acct = 'AT Specialist/Lending Library'
      elsif user.registration_type == 'parent'
        acct = 'Supervisor Parent Account'
      elsif user.registration_type == 'teacher'
        acct = 'Teacher'
      elsif user.registration_type == 'manually-added-supervisor'
        acct = 'Org Added Supervisor'
      elsif user.registration_type == 'other'
        acct = 'Supervisor other'
      else
        acct = 'Therapist'
      end
    elsif user.registration_type == 'other'
      acct = 'Communicator other'
    elsif user.registration_type == 'manually-added-org-user'
      acct = 'Org added Communicator'
    end

    name = (user.settings['name'] || '').split(/\s/, 2)
    json = {
      properties: [
        {property: 'email', value: email },
        {property: 'firstname', value: name[0]},
        {property: 'lastname', value: name[1]},
        {property: 'city', value: city},
        {property: 'username', value: user.user_name},
        # {property: 'hs_language', value: 'en'},
        {property: 'state', value: state},
        {property: 'account_type', value: acct},
        {property: 'hs_legal_basis', value: 'Legitimate interest – prospect/lead'}
      ]
    }
    if user && (user.settings['activations'] || []).length > 0
      json[:properties] << {
        property: 'coughdrop_start_code', value: user.settings['activations'].map{|a| a['code'] }.compact[-1]
      }
    end
  
    url = "https://api.hubapi.com/contacts/v1/contact/"
    res = Typhoeus.post(url, {body: json.to_json, headers: {
      'Content-Type' => 'application/json',
      'Authorization' => "Bearer #{ENV['HUBSPOT_TOKEN']}"
      }})
    # if res.code > 299
    #   puts res.body
    # end
    res.code
  end
end
