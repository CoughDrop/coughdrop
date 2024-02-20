module Renaming
  extend ActiveSupport::Concern
  
  def old_link?
    !!@old_link
  end
  
  def collision_error?
    !!@collision_error
  end 

  def invalid_name_error?
    !!@invalid_name
  end 
  
  def record_type
    @type ||= self.class.record_type
  end

  def rename_to(to_key)
    to_key = to_key.downcase
    @collision_error = nil
    @invalid_name = nil
    from_key = (record_type == 'board' ? self.key : self.user_name)
    record = self
    if self.class.find_by_path(to_key)
      @collision_error = true
      Rails.logger.warn("ACTION RENAMING rename_to------------------------collision_error: #{@collision_error}")

      return false
    elsif to_key.match(/^\d/)
      @invalid_name = true
      Rails.logger.warn("ACTION RENAMING rename_to------------------------to_key: #{to_key}")

      return false
    end
    Rails.logger.warn("ACTION RENAMING rename_to------------------------collision_error: #{@collision_error}")

    Rails.logger.warn("ACTION RENAMING rename_to------------------------to_key: #{to_key}")
    Rails.logger.warn("ACTION RENAMING rename_to------------------------from_key: #{from_key}")


    if record_type == 'board'
      old_prefix = from_key.split(/\//)[0]
      new_prefix = to_key.split(/\//)[0]
      old_postfix = from_key.split(/\//)[1]
      new_postfix = to_key.split(/\//)[1]
      return false if old_prefix != new_prefix && old_postfix != new_postfix
      return false if from_key == to_key
    end
    
    # - rename the actual key/users
    if record_type == 'board'
      self.key = to_key
    else
      self.user_name = to_key
    end
    self.save
    # - schedule an update to any references
    Worker.schedule_for(:slow, self.class, :perform_action, {
      'id' => self.id,
      'method' => 'rename_deep_links',
      'arguments' => [from_key]
    })
#    schedule(:rename_deep_links, from_key)
    OldKey.where(:type => record_type, :key => from_key).update_all(:record_id => record.global_id)
    if !OldKey.find_by(:type => record_type, :key => from_key)
      OldKey.create(:type => record_type, :key => from_key, :record_id => record.global_id)
    end
    true
  end
  
  def rename_deep_links(from_key)
    record = self
    to_key = (record_type == 'board') ? self.key : self.user_name
    raise "must be renamed already" if from_key == to_key
    raise "cannot rename for shallow clones" if @sub_id || (self.is_a?(Board) && self.shallow_source)
    if record_type == 'board'
      # Stuff that's being updated
      # - Board.buttons[idx][load_board][key]
      # - User.preferences[home_board][key]
      # - LogSession.events[idx][button][board][key]
      # - LogSession.events[idx][action][previous_key][key]
      # - LogSession.events[idx][action][new_id][key]
      # - User.boards_shared_with_me[idx][key]
      # - User.sidebar_boards[idx][key]
      # - BoardDownstreamButtonSet.buttons[idx][board_key]
      # - BoardDownstreamButtonSet.buttons[idx][linked_board_key]
      # TODO: still need to track
      # - Utterance.button_list[idx][board][key]
      board_ids = record.settings['immediately_upstream_board_ids'] || []
      Board.find_all_by_global_id(board_ids).each do |board|
        changed = false
        board.buttons.each do |button|
          if button['load_board'] && button['load_board']['id'] == global_id && button['load_board']['key'] != to_key
            button['load_board']['key'] = to_key
            changed = true
          end
        end
        board.save if changed
      end
      all_up_ids = []
      while all_up_ids != board_ids
        all_up_ids = board_ids
        Board.find_all_by_global_id(board_ids).each do |board|
          board_ids += board.settings['immediately_upstream_board_ids'] || []
        end
        board_ids = board_ids.uniq.sort
      end
      Board.find_all_by_global_id(all_up_ids).each do |board|
        # BoardDownstreamButtonSet.schedule_once(:update_for, board.global_id)
      end
      User.find_all_by_global_id(record.shared_user_ids).each do |user|
        changed = false
        (user.settings['boards_shared_with_me'] || []).each do |brd|
          if brd['board_key'] == from_key
            brd['board_key'] = to_key 
            changed = true
          end
        end
        user.save_with_sync('deep_links') if changed
      end
      UserLink.where(record_code: Webhook.get_record_code(record)).each do |link|
        if link.data && link.data['type'] == 'board_share' && link.data['state']
          if link.data['state']['board_key'] != to_key
            link.data['state']['board_key'] = to_key
            link.save
          end
        end
      end
      UserBoardConnection.where(:board_id => record.id, :home => true).each do |ubc|
        user = ubc.user
        if user.settings && user.settings['preferences'] && user.settings['preferences']['home_board'] && user.settings['preferences']['home_board']['id'] == global_id && user.settings['preferences']['home_board']['key'] != to_key
          user.settings['preferences']['home_board']['key'] = to_key
          user.save_with_sync('deep_links_connect')
        end
      end
      LogSessionBoard.where(:board_id => record.id).each do |lsb|
        Octopus.using(:master) do
          session = lsb.log_session
#          session.with_lock do
          if session
            session.assert_extra_data
            changed = false
            (session.data['events'] || []).each do |event|
              if event['button'] && event['button']['board'] && event['button']['board']['id'] == record.global_id && event['button']['board']['key'] != to_key
                event['button']['board']['key'] = to_key
                changed = true
              elsif event['action'] && event['action']['previous_key'] && event['action']['previous_key']['key']
                event['action']['previous_key']['key'] = to_key if event['action']['previous_key']['key'] == from_key
                event['action']['new_id']['key'] = to_key if event['action']['new_id'] && event['action']['new_id']['key'] == from_key
                changed = true
              end
            end
            session.save if changed
          end
        end
      end
    elsif record_type == 'user'
      # Stuff that's being updated
      # - ButtonImage.license[author_url]
      # - ButtonSound.license[author_url]
      # - User.supervisors[idx][user_name]
      # - User.supervisees[idx][user_name]
      # - User.boards_i_shared[idx][user_name]
      # - UserLink.data[state][supervis(ee|or)_user_name]
      # TODO: still need to track
      # - LogSession.note[author]
      # - UserVideo.comments[idx][user_name]
      klasses = [ButtonImage, ButtonSound, Board]
      # rename all boards
      record.boards.each do |board|
        postfix = board.key.split(/\//)[1]
        board.rename_to(record.user_name + '/' + postfix)
      end
      # TODO: sharding
      UserLink.where(user_id: record.id).each do |link|
        if link.data && link.data['state'] && link.data['type'] == 'supervisor'
          if link.data['state']['supervisee_user_name'] != to_key
            link.data['state']['supervisee_user_name'] = to_key 
            link.save
          end
        elsif link.data && link.data['type'] == 'board_share' && link.data['state']
          if link.data['state']['user_name'] != to_key
            link.data['state']['user_name'] = to_key 
            link.save
          end
        end
      end
      UserLink.where(secondary_user_id: record.id).each do |link|
        if link.data && link.data['type'] == 'board_share' && link.data['state']
          if link.data['state']['sharer_user_name'] != to_key
            link.data['state']['sharer_user_name'] = to_key 
            link.save
          end          
        end
      end
      UserLink.where(record_code: Webhook.get_record_code(record)).each do |link|
        if link.data && link.data['state'] && link.data['type'] == 'supervisor'
          if link.data['state']['supervisor_user_name'] != to_key
            link.data['state']['supervisor_user_name'] = to_key 
            link.save
          end
        end
      end
      (record.settings['boards_shared_with_me'] || []).each do |hash|
        board = Board.find_by_path(hash['board_id'])
        user = board && board.user
        if board && board.user
          (board.user.settings['boards_i_shared'] || {}).keys.each do |key|
            changed = false
            board.user.settings['boards_i_shared'][key].each do |brd|
              if brd['user_name'] == from_key
                brd['user_name'] = to_key 
                changed = true
              end
            end
            board.user.save if changed
          end
        end
      end
      (record.settings['supervisees'] || []).each do |sup|
        user = User.find_by_path(sup['user_id'])
        if user
          user.settings['supervisors'].each do |ss|
            ss['user_name'] = to_key if ss['user_name'] == from_key
          end
          user.save_with_sync('deep_links_supervisee')
        end
      end
      (record.settings['supervisors'] || []).each do |sup|
        user = User.find_by_path(sup['user_id'])
        if user
          user.settings['supervisees'].each do |ss|
            ss['user_name'] = to_key if ss['user_name'] == from_key
          end
          user.save_with_sync('deep_links_supervisor')
        end
      end
      klasses.each do |klass|
        klass.where(:user_id => record.id).each do |bi|
          if bi.settings['license'] && bi.settings['license']['author_url'] && bi.settings['license']['author_url'].match(/#{from_key}$/)
            bi.settings['license']['author_url'] = bi.settings['license']['author_url'].sub(/#{from_key}$/, to_key)
            bi.save
          end
        end
      end
    end
  end


  module ClassMethods
    def record_type
      return @type if @type
      if self == Board
        @type = 'board'
      elsif self == User
        @type = 'user'
      else
        @type = 'other'
      end
      @type
    end
    
    def find_by_possibly_old_path(path)
      res = find_by_path(path)
      if !res
        key = OldKey.find_by(:type => record_type, :key => path)
        res = key && key.record
        res.instance_variable_set('@old_link', true) if res
      end
      res
    end
  end
end