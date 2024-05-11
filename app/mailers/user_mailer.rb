class UserMailer < ActionMailer::Base
  include General
  helper MailerHelper
  default from: ENV['DEFAULT_EMAIL_FROM']
  layout 'email'
  
  def self.bounce_email(email)
    hash = User.generate_email_hash(email)
    users = User.where(:email_hash => hash)
    users.each do |user|
      user.update_setting('email_disabled', true)
    end
  end

  def new_user_registration(user_id)
    @user = User.find_by_global_id(user_id)
    d = @user.devices[0]
    ip = d && d.settings['ip_address']
    @location = nil
    if ip && ENV['IPSTACK_KEY']
      url = "http://api.ipstack.com/#{ip}?access_key=#{ENV['IPSTACK_KEY']}"
      begin
        res = Typhoeus.get(url, timeout: 5)
        json = JSON.parse(res.body)
        @location = json && "#{json['city']}, #{json['region_name']}, #{json['country_code']}"
      rescue => e
      end
    end
    recipient = JsonApi::Json.current_domain['settings']['admin_email'] || ENV['NEW_REGISTRATION_EMAIL']
    if recipient
      user_type = @user.supporter_registration? ? 'Supervisor' : 'Communicator'
      mail(to: recipient, subject: "#{app_name} - New #{user_type} Registration", reply_to: @user.settings['email'])
    end
  end

  def eval_welcome(user_id)
    @user = User.find_by_path(user_id)
  end
  
  def password_changed(user_id)
    @user = User.find_by_global_id(user_id)
    mail_message(@user, "Password Changed")
  end
  
  def email_changed(user_id)
    @user = User.find_by_global_id(user_id)
    mail_message(@user, "Email Changed")
    @old_email = true
    mail_message(@user, "Email Changed", 'email_changed_prior_address')
  end
  
  def badge_awarded(user_id, badge_id)
    @recipient = User.find_by_global_id(user_id)
    @badge = UserBadge.find_by_global_id(badge_id)
    @user = @badge.user
    @goal = @badge.user_goal
    @for_self = @badge.user_id == @recipient.id
    mail_message(@recipient, "Badge Awarded")
  end
  
  def confirm_registration(user_id)
    @user = User.find_by_global_id(user_id)
    mail_message(@user, "Welcome!")
  end

  def user_activated(user_id)
    Rails.logger.warn("UserMailer------------------")

    @user = User.find_by_global_id(user_id)
    if @user.present?
      mail_message(@user, "Account Activation Notification!")
    end
  end

  def user_deactivated(user_id)
    Rails.logger.warn("UserMailer------------------")

    @user = User.find_by_global_id(user_id)
    if @user.present?
      mail_message(@user, "Account Deactivation Notification!")
    end
  end

  def welcome_confirm_registration(user_id)
    @user = User.find_by_global_id(user_id)
    mail_message_with_bcc(@user, "Get the most out of CoughDrop!")
  end
  
  def login_no_user(email)
    @email = email
    @full_domain = full_domain_enabled
    mail(to: email, subject: "#{app_name} - Login Help")
  end
  
  def forgot_password(user_ids)
    @users = User.find_all_by_global_id(user_ids)
    @user = @users.first
    mail_message(@user, "Forgot Password Confirmation")
  end
  
  def log_message(user_id, log_id)
    @user = User.find_by_global_id(user_id)
    @log = LogSession.find_by_global_id(log_id)
    @author = @log.author
    @author_name = (@log.data['author_contact'] || {})['name'] || @author.settings['name']
    @target = @log.user
    mail_message(@user, "New Message")
  end
  
  def log_summary(user_id)
    @user = User.find_by_global_id(user_id)
    @supervisees = User.find_all_by_global_id(@user.supervised_user_ids)
    @log_duration = 'the last week'
    @log_period = 'week'
    pre_start = 2.weeks.ago
    pre_end = 1.week.ago
    if @user.settings['next_notification_delay'] == '2_weeks'
      pre_start = 4.weeks.ago
      pre_end = 2.weeks.ago
      @log_duration = 'the last two weeks'
      @log_period = 'two weeks'
    elsif @user.settings['next_notification_delay'] == '1_month'
      pre_start = 2.months.ago
      pre_end = 1.month.ago
      @log_duration = 'the last month'
      @log_period = 'month'
    end
    @users = []
    users_to_check = []
    users_to_check << @user if @user.any_premium_or_grace_period? && @user.settings['preferences'] && @user.settings['preferences']['role'] == 'communicator'
    users_to_check += @supervisees
    
    users_to_check.uniq.each do |user|
      # collect stats for the time period
      # also should compare to last time period
      # - total sessions (delta vs. last time period)
      # - total buttons (delta vs. last time period)
      # - new words since last time period
      # - lost words since last time period
      # - number of new notes in time period (with link if any)
      # - primary goal status weighted average (vs. last time period)
      # - link to update primary goal status
      pre_stats = nil
      current_stats = nil
      user_report = OpenStruct.new({
        :label => user.user_name,
        :user_name => user.user_name,
        :premium => user.any_premium_or_grace_period?,
        :pre_start => pre_start.iso8601[0, 10],
        :pre_end => pre_end.iso8601[0, 10],
        :start => pre_end.iso8601[0, 10],
        :end => Time.now.iso8601[0, 10]
      })
      begin
        if user.any_premium_or_grace_period? && user.settings['preferences'] && user.settings['preferences']['role'] == 'communicator'
          user_report.pre_stats = Stats.cached_daily_use(user.global_id, {:start_at => pre_start, :end_at => pre_end})
          user_report.current_stats = Stats.cached_daily_use(user.global_id, {:start_at => pre_end, :end_at => Time.now})
          broad_state = Stats.cached_daily_use(user.global_id, {:start_at => [pre_start, 4.weeks.ago].min, :end_at => Time.now})
          # TODO: sharding
          user_report.total_notes = LogSession.where(:user_id => user.id).where(:log_type => ['note', 'assessment']).where(['started_at > ? AND ended_at < ?', pre_start, Time.now]).count
          user_report.primary_goal = UserGoal.primary_goal(user)
          user_report.secondary_goal_count = UserGoal.secondary_goals(user).length
          if user_report.pre_stats[:total_sessions] > 0
            user_report.total_sessions_delta = (user_report.current_stats[:total_sessions].to_f / user_report.pre_stats[:total_sessions].to_f * 100.0).round(0) - 100.0
            # if user_report.current_stats[:total_sessions].to_f < user_report.pre_stats[:total_sessions].to_f
            #   user_report.total_sessions_delta = (user_report.current_stats[:total_sessions].to_f / user_report.pre_stats[:total_sessions].to_f * 100.0).round(0) - 100.0
            # end
          end
          if user_report.pre_stats[:modeled_buttons] > 0
            user_report.modeled_buttons_delta = (user_report.current_stats[:modeled_buttons].to_f / user_report.pre_stats[:modeled_buttons].to_f * 100.0).round(0) - 100.0
          end
          if user_report.pre_stats[:total_buttons] > 0
            user_report.total_buttons_delta = (user_report.current_stats[:total_buttons].to_f / user_report.pre_stats[:total_buttons].to_f * 100.0).round(0) - 100.0
            # if user_report.current_stats[:total_buttons].to_f < user_report.pre_stats[:total_buttons].to_f 
            #   user_report.total_buttons_delta = (user_report.current_stats[:total_buttons].to_f / user_report.pre_stats[:total_buttons].to_f * 100.0).round(0) - 100.0
            # end
          end
          user_report.lost_words = (broad_state[:dwindling_words] || []).sort_by(&:last).reverse.map(&:first).join(', ')
          user_report.gained_words = (broad_state[:emergent_words] || []).sort_by(&:last).reverse.map(&:first).join(', ')

          if user_report.gained_words.length == 0
            # lost_percents = []
            # # TODO: this really shouldn't be in a mailer, put it in a lib or something
            # user_report.pre_stats[:words_by_frequency].each do |word|
            #   pre_percent = word['count'].to_f / user_report.pre_stats[:total_words].to_f
            #   found_word = user_report.current_stats[:words_by_frequency].detect{|w| w['text'] == word['text'] }
            #   post_percent = found_word ? (found_word['count'].to_f / user_report.current_stats[:total_words].to_f) : 0.0
            #   if post_percent < pre_percent
            #     res = {
            #       :text => word['text'],
            #       :multiplier => pre_percent / post_percent
            #     }
            #     if post_percent == 0
            #       res[:multiplier] = pre_percent * 100.0 * 10.0
            #     end
            #     lost_percents.push(res)
            #   end
            # end
            # lost_percents = lost_percents.sort_by{|p| p[:multiplier] }.reverse
            # user_report.lost_words = lost_percents[0, 10].map{|p| p[:text] }.join(', ')

            # gained_percents = []
            # user_report.current_stats[:words_by_frequency].each do |word|
            #   post_percent = word['count'].to_f / user_report.current_stats[:total_words].to_f
            #   found_word = user_report.pre_stats[:words_by_frequency].detect{|w| w['text'] == word['text'] }
            #   pre_percent = found_word ? (found_word['count'].to_f / user_report.pre_stats[:total_words].to_f) : 0.0
            #   if post_percent > pre_percent
            #     res = {
            #       :text => word['text'],
            #       :multiplier => post_percent / pre_percent
            #     }
            #     if pre_percent == 0
            #       res[:multiplier] = post_percent * 100.0 * 10.0
            #     end
            #     gained_percents.push(res)
            #   end
            # end
            # gained_percents = gained_percents.sort_by{|p| p[:multiplier] }.reverse
            # user_report.gained_words = gained_percents[0, 10].map{|p| p[:text] }.join(', ')
          end

          # TODO: average goal status specific to the time range, plus delta
        end
      rescue Stats::StatsError => e
      end
      @users << user_report
    end
    mail_message(@user, "Communication Report")
  end

  def usage_reminder(user_id)
    return unless full_domain_enabled
    @user = User.find_by_global_id(user_id)
    
    @logging_disabled = !@user.settings['preferences']['logging']
    @no_recent_activity = @user.devices.all?{|d| d.updated_at < 4.days.ago}
    @no_home_board = @user.settings['preferences']['home_board']
    @supporter = @user.settings['preferences']['role'] == 'supporter'
    @supporter_no_supervisees = @user.settings['preferences']['role'] == 'supporter' && @user.supervised_user_ids.empty?
    @no_subscription = @user.grace_period?

    mail_message(@user, "Checking In")
  end
  
  def utterance_share(opts)
    @user = User.find_by_global_id(opts['sharer_id'])
    @recipient = User.find_by_global_id(opts['recipient_id'])
    @sender = @user && @user.settings['name']
    @sender ||= @user && @user.user_name
    @sender ||= opts['sharer_name']
    @sender ||= 'someone'
    @reply_url = opts['reply_url']
    if opts['reply_id']
    end
    @prior = LogSession.find_reply(opts['reply_id'], @user, @recipient)
    @message = opts['message'] || "no message"
    mail(to: opts['to'], subject: opts['subject'], reply_to: @user.settings['email'])
  end

  def lesson_assigned(lesson_id, user_ids)
    @lesson = Lesson.find_by_path(lesson_id)
    User.find_batches_by_global_id(user_ids) do |u|
      @user = u
      mail(to: u.named_email, subject: "#{app_name} - New Lesson Assigned")
    end
  end
  
  def organization_assigned(user_id, org_id)
    @user = User.find_by_global_id(user_id)
    @org = Organization.find_by_global_id(org_id)
    mail_message(@user, "Organization Sponsorship Added") if @user && @org
  end
  
  def organization_unassigned(user_id, org_id)
    @user = User.find_by_global_id(user_id)
    @org = Organization.find_by_global_id(org_id)
    if !UserLink.links_for(@user).detect{|l| l['type'] == 'org_user' && l['record_code'] == Webhook.get_record_code(@org)}
      mail_message(@user, "Organization Sponsorship Removed") if @user && @org
    end
  end

  def valet_password_enabled(user_id)
    @user = User.find_by_global_id(user_id)
    @re_enable = true if @user.settings['valet_password_disabled_since'] && @user.settings['valet_password_disabled_since'] > 4.weeks.ago.to_i
    mail_message(@user, "Valet Login Enabled") if @user
  end
  
  def valet_password_used(user_id)
    @user = User.find_by_global_id(user_id)
    mail_message(@user, "Valet Login Used") if @user
  end

end
