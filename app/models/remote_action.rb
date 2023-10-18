class RemoteAction < ApplicationRecord
  def process_action
    ra = self
    if ra.action == 'delete'
      if ra.path && ra.extra
        Worker.schedule_for(:slow, Uploader, :remote_remove, ra.path, ra.extra)
      end
    elsif ra.action == 'notify_unassigned'
      user_id, org_id = ra.path.split(/::/, 2)
      UserMailer.schedule_delivery(:organization_unassigned, user_id, org_id)
    elsif ra.action == 'upload_button_set'
      board_id, user_id = ra.path.split(/::/, 2)
      BoardDownstreamButtonSet.schedule_for(:slow, :update_for, board_id, true)
    elsif ra.action == 'upload_log_session'
      session = LogSession.find_by_global_id(ra.path)
      if session
        session.schedule_for(:slow, :detach_extra_data, true)
      end
    elsif ra.action == 'upload_extra_data'
      board_id, user_id = ra.path.split(/::/, 2)
      BoardDownstreamButtonSet.schedule_for(:slow, :generate_for, board_id, user_id)
    elsif ra.action == 'queued_goals'
      UserGoal.schedule(:handle_goals, ra.path)
    elsif ra.action == 'weekly_stats_update'
      user_id, weekyear = ra.path.split(/::/, 2)
      WeeklyStatsSummary.schedule(:update_now, user_id, weekyear)
    elsif ra.action == 'update_available_boards'
      user = User.find_by_path(ra.path)
      user.schedule_once_for(:slow, :update_available_boards) if user
    elsif ra.action == 'update_library_cache'
      cache = LibraryCache.find_by_global_id(ra.path)
      cache.schedule_for(:slow, :find_expired_words) if cache
    elsif ra.action == 'badge_check'
      user_id, summary_id = ra.path.split(/::/, 2)
      UserBadge.schedule_once_for('slow', :check_for, user_id, summary_id)
    elsif ra.action == 'schedule_update_available_boards'
      board = Board.find_by_path(ra.path)
      board.schedule_once_for(:slow, :schedule_update_available_boards, ra.extra || 'all', true) if board
    elsif ra.action == 'track_downstream_with_visited'
      board = Board.find_by_path(ra.path)
      ts = ((board && (board.settings || {})['last_tracked']) || 0) - 1
      board.schedule_once_for(:slow, :track_downstream_with_visited) if board && ts < ra.updated_at.to_i
    elsif ra.action == 'save_sync_supervisors'
      user = User.find_by_path(ra.path)
      user.schedule(:save_sync_supervisors, true) if user
    elsif ra.action == 'audit_protected_sources'
      user = User.find_by_path(ra.path)
      user.schedule(:audit_protected_sources) if user
    end
  end

  def self.process_all
    RemoteAction.all.each{|ra| ra.process_action; ra.destroy }
  end
end
