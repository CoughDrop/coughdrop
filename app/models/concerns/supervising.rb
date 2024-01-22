module Supervising
  extend ActiveSupport::Concern
  
  def generate_link_code
    return nil unless self.any_premium_or_grace_period?
    code = GoSecure.nonce('link_code')[0, 5]
    self.settings['link_codes'] ||= []
    self.settings['link_codes'].select!{|c| id, nonce, ts = c.split(/-/, 3); Time.at(ts.to_i) > 6.hours.ago }
    code = "#{self.global_id}-#{code}-#{Time.now.to_i}"
    self.settings['link_codes'] << code
    self.save
    code
  end
  
  def link_to_supervisee_by_code(code)
    return false unless code
    id, nonce, ts = code.split(/-/, 3)
    user = User.find_by_global_id(id)
    user = nil unless user && user.any_premium_or_grace_period? &&
        (user.settings['link_codes'] || []).include?(code) && 
        Time.at(ts.to_i) > 6.hours.ago
    return false unless user && user != self
    supervisors = User.find_all_by_global_id(user.supervisor_user_ids)
    non_premium_supervisors = supervisors.select{|u| !u.any_premium_or_grace_period? }
    return false if non_premium_supervisors.length >= 5
    self.save unless self.id
    self.class.link_supervisor_to_user(self, user, code)
    true
  end
  
  def supervisor_user_ids
    sups = UserLink.links_for(self).select{|l| l['type'] == 'supervisor' && l['user_id'] == self.global_id}
    sups.map{|l| l['record_code'].split(/:/)[1] }.uniq
  end
  
  def supervisor_links
    return [] unless self.id
    UserLink.links_for(self).select{|l| l['type'] == 'supervisor' && l['user_id'] == self.global_id }
  end
  
  def supervisor_for?(user)
    user.supervisor_user_ids.include?(self.global_id) || Organization.manager_for?(self, user)
  end
  
  def supervisors
    if !self.supervisor_user_ids.blank?
      User.find_all_by_global_id(self.supervisor_user_ids)
    else
      []
    end
  end
  
  def managing_organization(pending=false)
    orgs = Organization.attached_orgs(self)
    org = orgs.detect{|o| o['type'] == 'user' && (pending ? o['pending'] : !o['pending']) && o['sponsored'] }
    org ||= orgs.detect{|o| o['type'] == 'user' && (pending ? o['pending'] : !o['pending']) }
    org ||= orgs.detect{|o| o['type'] == 'user' }
    if org
      Organization.find_by_global_id(org['id'])
    else
      nil
    end
  end
  
  def organization_hash
    res = []
    res += Organization.attached_orgs(self)
    res.reverse.uniq{|e| [e['id'], e['type']] }.sort_by{|e| e['id'] }
  end

  def supervisee_links
    return [] unless self.id
    code = Webhook.get_record_code(self)
    UserLink.links_for(self).select{|l| l['type'] == 'supervisor' && l['record_code'] == code }
  end
  
  def supervised_user_ids
    supervisee_links.map{|l| l['user_id'] }.compact.uniq
  end
  
  def supervisees
    if !self.supervised_user_ids.blank?
      User.find_all_by_global_id(self.supervised_user_ids).sort_by(&:user_name)
    else
      []
    end
  end
  
  def edit_permission_for?(supervisee, include_admin_managers=true)
    return false if self.valet_mode?
    sup = !self.modeling_only? && supervisee.supervisor_links.any?{|l| l['record_code'] == Webhook.get_record_code(self) && l['user_id'] == supervisee.global_id && l['state']['edit_permission'] } 
    sup || Organization.manager_for?(self, supervisee, include_admin_managers)
  end

  def modeling_only_for?(supervisee, include_admin_managers=true)
    return true if self.modeling_only?
    supervisee.supervisor_links.any?{|l| l['record_code'] == Webhook.get_record_code(self) && l['user_id'] == supervisee.global_id && l['state']['modeling_only'] } 
  end

  def org_units_for_supervising(supervisee)
    unit_ids = supervisee_links.map{|l| l['state']['organization_unit_ids'] }.compact.flatten.uniq
    OrganizationUnit.find_all_by_global_id(unit_ids)
  end
  
  def process_supervisor_key(key)
    action, key = key.split(/-/, 2)
    action_parts = action.split(/_/)
    if action_parts[0] == 'add'
      return false unless self.any_premium_or_grace_period? && self.id
      supervisor = User.find_by_path(key)
      if key.match(/@/)
        users = User.find_by_email(key)
        if users.length == 1
          supervisor = users[0]
        end
      end
      return false if !supervisor || self == supervisor
      grant_code = nil
      grant_code = 'granted' if action_parts.include?('premium') && self.premium_supporter_grants > 0
      type = nil
      type = 'edit' if action_parts.include?('edit')
      type = 'modeling_only' if action_parts.include?('modeling')
      self.class.link_supervisor_to_user(supervisor, self, nil, type, grant_code)
      return true
    elsif action == 'approve' && key == 'org'
      self.settings['pending'] = false
      self.update_subscription_organization(self.managing_organization(true).global_id, false, nil, nil)
      true
    elsif action == 'approve_supervision'
      org = Organization.find_by_global_id(key)
      if org.pending_supervisor?(self)
        org.approve_supervisor(self)
        true
      elsif org.supervisor?(self)
        true
      else
        false
      end
    elsif action == 'remove_supervision'
      org = Organization.find_by_global_id(key)
      org.reject_supervisor(self)
      true
    elsif action == 'remove_supervisor'
      if key.match(/^org/)
        org_id = key.split(/-/)[1]
        org_id ||= self.managing_organization && self.managing_organization.global_id
        self.update_subscription_organization("r#{org_id}") if org_id
      else
        supervisor = User.find_by_path(key)
        user = self
        return false unless supervisor && user
        self.class.unlink_supervisor_from_user(supervisor, user)
      end
      true
    elsif action == 'remove_supervisee'
      supervisor = self
      user = User.find_by_path(key)
      return false unless supervisor && user
      self.class.unlink_supervisor_from_user(supervisor, user)
    elsif action == 'start'
      res = Organization.parse_activation_code(key, self)
      return false if !res || res[:disabled]
      @start_code_progress = res[:progress]
      return true
    else
      return false
    end
  end
  
  def remove_supervisors!
    user = self
    self.supervisors.each do |sup|
      User.unlink_supervisor_from_user(sup, user)
    end
  end
  
  module ClassMethods  
    def unlink_supervisor_from_user(supervisor, user, organization_unit_id=nil)
      supervisor = user if supervisor.global_id == user.global_id
      sup = (user.settings['supervisors'] || []).detect{|s| s['user_id'] == supervisor.global_id }
      org_unit_ids = (sup || {})['organization_unit_ids'] || []
      org_unit_ids += UserLink.links_for(user).select{|l| l['type'] == 'supervisor' && l['user_id'] == user.global_id && l['record_code'] == Webhook.get_record_code(supervisor) }.map{|l| l['state'] && l['state']['organization_unit_ids'] }.compact.flatten
      org_unit_ids.uniq!
      
      user.settings['supervisors'] = (user.settings['supervisors'] || []).select{|s| s['user_id'] != supervisor.global_id }
      do_unlink = true
      if organization_unit_id && (org_unit_ids - [organization_unit_id]).length > 0
        org_unit_ids -= [organization_unit_id]
        link = UserLink.generate(user, supervisor, 'supervisor')
        link.data['state']['organization_unit_ids'] = org_unit_ids
        link.save!
        do_unlink = false
      else
        UserLink.remove(user, supervisor, 'supervisor')
      end
      user.update_setting({
        'supervisors' => user.settings['supervisors']
      })
      user.using(:master).reload
      if do_unlink
        supervisor.using(:master).reload
        supervisor.settings['supervisees'] = (supervisor.settings['supervisees'] || []).select{|s| s['user_id'] != user.global_id }
        # If a user was auto-subscribed for being added as a supervisor, un-subscribe them when removed
        if supervisor.settings['supervisees'].empty? && supervisor.settings['supporter_role_auto_set']
          supervisor.settings.delete('supporter_role_auto_set')
          supervisor.settings['preferences']['role'] = 'communicator'
          supervisor.save_with_sync('un-supervisor')
        end
        supervisor.schedule_once(:update_available_boards)
        supervisor.update_setting({
          'supervisees' => supervisor.settings['supervisees']
        })
      end
    end
    
    def link_supervisor_to_user(supervisor, user, code=nil, type=true, organization_unit_id=nil)
      Rails.logger.warn("SUPERVISING link_supervisor_to_user-----------------------supervisor, user: #{supervisor}, #{user}")
      
      type = 'edit' if type == true
      type ||= 'read_only'
      supervisor = user if supervisor.global_id == user.global_id
      
      grant_premium = false
      if organization_unit_id == 'granted'
        grant_premium = true
        organization_unit_id = nil
      end
      org_unit_ids = ((user.settings['supervisors'] || []).detect{|s| s['user_id'] == supervisor.global_id } || {})['organization_unit_ids'] || []
      org_unit_ids += UserLink.links_for(user).select{|l| l['type'] == 'supervisor' && l['record_code'] == Webhook.get_record_code(supervisor) }.map{|l| l['state'] && l['state']['organization_unit_ids'] }.compact.flatten

      link = UserLink.generate(user, supervisor, 'supervisor')
      Rails.logger.warn("SUPERVISING link_supervisor_to_user-----------------------link, TYPE: #{link}, #{type}")

      link.data['state']['edit_permission'] = true if type == 'edit'
      link.data['state']['modeling_only'] = true if type == 'modeling_only'
      link.data['state']['supervisee_user_name'] = user.user_name
      link.data['state']['supervisor_user_name'] = supervisor.user_name
      link.data['state']['organization_unit_ids'] = ((org_unit_ids || []) + ([organization_unit_id].compact)).uniq
      link.secondary_user_id = supervisor.id
      link.save!

      supervisor.using(:master).reload
      # first-time supervisors should automatically be set to the supporter role
      if !supervisor.settings['supporter_role_auto_set'] && supervisor.settings['preferences']['role'] != 'supporter'
        supervisor.settings['supporter_role_auto_set'] = true
        supervisor.settings['preferences']['role'] = 'supporter'
      end
      if grant_premium && user.premium_supporter_grants > 0 && supervisor.supporter_role? && supervisor.billing_state != :premium_supporter
        user.grant_premium_supporter(supervisor)
      end
      # If a user is on a free trial and they're added as a supervisor, set them to a free supporter subscription
      if supervisor.grace_period?
        supervisor.schedule(:remove_supervisors!)
        supervisor.settings['preferences']['role'] = 'supporter'
      end

      Rails.logger.warn("SUPERVISING link_supervisor_to_user-----------------------supervisor.settings: #{supervisor.settings}")
      
      supervisor.schedule_once(:update_available_boards)
      user.save_with_sync('supervisee')
      supervisor.save_with_sync('supervisor')
    end
  end
end