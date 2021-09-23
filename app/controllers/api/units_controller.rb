class Api::UnitsController < ApplicationController
  before_action :require_api_token

  def index
    org = Organization.find_by_global_id(params['organization_id'])
    return unless exists?(org, params['organization_id'])
    return unless allowed?(org, 'edit')
    
    # TODO: sharding
    @units = OrganizationUnit.where(:organization_id => org.id).order('position, id ASC')
    @units = @units.to_a.sort_by{|u| (u.settings['name'] || 'Unnamed Room').downcase }
    render json: JsonApi::Unit.paginate(params, @units)
  end
  
  def create
    org = Organization.find_by_global_id(params['unit']['organization_id'])
    return unless exists?(org, params['unit']['organization_id'])
    return unless allowed?(org, 'edit')
    @unit = OrganizationUnit.process_new(params['unit'], {:organization => org})
    if @unit.errored?
      api_error(400, {error: "unit creation failed", errors: @unit && @unit.processing_errors})
    else
      render json: JsonApi::Unit.as_json(@unit, :wrapper => true, :permissions => @api_user).to_json
    end
  end

  def note
    unit = OrganizationUnit.find_by_global_id(params['unit_id'])
    return unless exists?(unit, params['unit_id'])
    return unless allowed?(unit, 'view_stats')

    video = nil
    if params['video_id']
      vid = UserVideo.find_by_global_id(params['video_id'])
      if vid
        video = {
          'id' => params['video_id'],
          'duration' => vid.settings['duration']
        }
      end
    end

    user_ids = UserLink.links_for(unit).select{|l| l['type'] == 'org_unit_communicator' }.map{|l| l['user_id'] }
    supervisor_ids = UserLink.links_for(unit).select{|l| l['type'] == 'org_unit_supervisor' }.map{|l| l['user_id'] }.compact.uniq
    targets = []
    if params['target'] == 'communicators'
      params['notify_exclude_ids'] = supervisor_ids
      targets = user_ids
    elsif params['target'] == 'supervisors'
      targets = supervisor_ids
    else
      targets = (user_ids + supervisor_ids).uniq
    end
    LogSession.schedule_for(:priority, :message_all, targets, {
      sender_id: @api_user.global_id,
      device_id: @api_device_id,
      message: params['note'],
      video: video,
      include_footer: params['include_footer'],
      notify_exclude_ids: params['notify_exclude_ids'],
      notify: params['notify_user'] ? 'include_user' : 'true'
    })
    render json: {targets: targets.length}
  end

  def stats
    unit = OrganizationUnit.find_by_global_id(params['unit_id'])
    return unless exists?(unit, params['unit_id'])
    return unless allowed?(unit, 'view_stats')

    user_ids = UserLink.links_for(unit).select{|l| l['type'] == 'org_unit_communicator' }.map{|l| l['user_id'] }
    approved_users = User.find_all_by_global_id(user_ids)
    supervisor_ids = UserLink.links_for(unit).select{|l| l['type'] == 'org_unit_supervisor' }.map{|l| l['user_id'] }.compact.uniq
    res = Organization.usage_stats(approved_users, false)

    res['user_weeks'] = {}
    sessions = LogSession.where(['started_at > ?', 12.weeks.ago]).where(:user_id => approved_users.map(&:id))
    sessions.group("date_trunc('week', started_at), user_id").select("count(*), date_trunc('week', started_at), user_id, count(goal_id) AS goals").each do |obj|
      if obj.attributes['user_id']
        user_id = unit.related_global_id(obj.attributes['user_id'])
        res['user_weeks'][user_id] ||= {}
        if obj.attributes['date_trunc']
          ts = obj.attributes['date_trunc'].to_time.to_i
          res['user_weeks'][user_id][ts] ||= {
            'count' => obj.attributes['count'] || 0,
            'goals' => obj.attributes['goals'] || 0,
          }
        end
      end
    end
    sessions.where(log_type: 'note').select("id, user_id, goal_id, started_at, score").find_in_batches(batch_size: 50) do |batch|
      batch.each do |session|
        if session.started_at && session.score && session.goal_id
          user_id = unit.related_global_id(session.user_id)
          from_sup = supervisor_ids.include?(user_id)
          ts = session.started_at.beginning_of_week(:monday).to_date.to_time(:utc).to_i
          res['user_weeks'][user_id][ts] ||= {'count' => 0, 'goals' => 0}
          res['user_weeks'][user_id][ts]['statuses'] ||= []
          res['user_weeks'][user_id][ts]['statuses'] << {goal_id: session.related_global_id(session.goal_id), score: session.score, from_unit: from_sup}
        end
      end
    end
    
    sessions = LogSession.where(log_type: 'daily_use', user_id: User.local_ids(supervisor_ids))
    res['supervisor_weeks'] = {}
    cutoff = 12.weeks.ago.to_date.iso8601
    sessions.each do |session|
      user_id = session.related_global_id(session.user_id)
      (session.data['days'] || []).each do |str, day|
        if str > cutoff
          week = Date.parse(str).beginning_of_week(:monday)
          ts = week.to_time(:utc).to_i
          res['supervisor_weeks'][user_id] ||= {}
          res['supervisor_weeks'][user_id][ts] ||= {
            'actives' => 0,
            'total_levels' => 0,
            'days' => 0
          }
          LogSession::DAILY_EVENT_TYPES.each do |key|
            if(day[key])
              res['supervisor_weeks'][user_id][ts][key] = (res['supervisor_weeks'][user_id][ts][key] || 0) + day[key]
            end
          end

          res['supervisor_weeks'][user_id][ts]['actives'] += 1 if day['active']
          res['supervisor_weeks'][user_id][ts]['total_levels'] += (day['activity_level'] ? day['activity_level'] : (day['active'] ? 4 : 0))
          res['supervisor_weeks'][user_id][ts]['days'] += 1 if day['active'] || day['activity_level']
          res['supervisor_weeks'][user_id][ts]['average_level'] = res['supervisor_weeks'][user_id][ts]['total_levels'].to_f / [5.0, res['supervisor_weeks'][user_id][ts]['days'].to_f].max
        end
      end
    end

    render json: res.to_json
  end

  def logs
    unit = OrganizationUnit.find_by_global_id(params['unit_id'])
    return unless exists?(unit, params['unit_id'])
    return unless allowed?(unit, 'view_stats')
    user_ids = UserLink.links_for(unit).select{|l| l['type'] == 'org_unit_communicator' }.map{|l| l['user_id'] }
    approved_users = User.find_all_by_global_id(user_ids).select{|u| !u.private_logging? }
    # TODO: sharding
    logs = LogSession.where(:user_id => approved_users.map(&:id)).order(id: :desc)
    prefix = "/units/#{unit.global_id}/logs"
    render json: JsonApi::Log.paginate(params, logs, {:prefix => prefix})
  end
    
  def show
    @unit = OrganizationUnit.find_by_global_id(params['id'])
    return unless exists?(@unit, params['id'])
    return unless allowed?(@unit, 'view')
    render json: JsonApi::Unit.as_json(@unit, :wrapper => true, :permissions => @api_user).to_json
  end

  def update
    @unit = OrganizationUnit.find_by_global_id(params['id'])
    return unless exists?(@unit, params['id'])
    return unless allowed?(@unit, 'edit')
    if @unit.process(params['unit'])
      @unit.reload
      render json: JsonApi::Unit.as_json(@unit, :wrapper => true, :permissions => @api_user).to_json
    else
      api_error(400, {error: "unit update failed", errors: @unit.processing_errors})
    end
  end
  
  def destroy
    @unit = OrganizationUnit.find_by_global_id(params['id'])
    return unless exists?(@unit, params['id'])
    return unless allowed?(@unit, 'delete')
    @unit.destroy
    render json: JsonApi::Unit.as_json(@unit, :wrapper => true, :permissions => @api_user).to_json
  end
end
