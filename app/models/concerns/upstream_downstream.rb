module UpstreamDownstream
  extend ActiveSupport::Concern
  LARGE_BOARD_LIST_LIMIT = 1300
  
  def track_downstream_boards!(already_visited_ids=[], buttons_changed=false, trigger_stamp=nil)
    already_visited_ids ||= []
    # short-circuit if board has been tracked by another process since this was originally scheduled
    return if self.class.last_scheduled_stamp && self.settings['last_tracked'] && self.settings['last_tracked'] > self.class.last_scheduled_stamp
    @track_downstream_boards = true
    Rails.logger.info("touching downstreams #{self.global_id}")
    self.touch_downstreams(already_visited_ids)
    self.track_downstream_boards(already_visited_ids, buttons_changed, trigger_stamp)
    Rails.logger.info("touching downstreams again #{self.global_id}")
    self.touch_downstreams(already_visited_ids)
    @track_downstream_boards = false
    true
  end
  
  def edit_stats
    gbs = self.grid_buttons
    {
      'total_buttons' => gbs.length,
      'unlinked_buttons' => gbs.select{|btn| !btn['load_board'] }.length,
      'current_revision' => self.current_revision
    }
  end
  
  def track_downstream_boards(already_visited_ids=[], buttons_changed=false, trigger_stamp=nil)
    return unless @track_downstream_boards
    return if already_visited_ids.include?(self.global_id)
    already_visited_ids << self.global_id
    trigger_stamp ||= Board.last_scheduled_stamp || Time.now.to_i

    top_board = self
    if @sub_id
      b = Board.find_by_path(self.global_id(true))
      return b.track_downstream_boards(already_visited_ids, buttons_changed, trigger_stamp)
    end
    # step 1: travel downstream, for every board id get its immediate children
    Rails.logger.info('getting all children')
    boards_with_children = {}
    board_edit_stats = {}
    unfound_boards = ["self"]

    # short-circuit individual lookups, since the board most likely already knows about most of
    # its downstreams, and only one or a few will be new or updated    
    board_limit = self.possible_home_board? ? LARGE_BOARD_LIST_LIMIT : LARGE_BOARD_LIST_LIMIT / 2
    if !self.possible_home_board? && RedisInit.any_queue_pressure?
      self.schedule_track(already_visited_ids)
      Rails.logger.info('too busy and this is not a home board, try later')
      return 'delayed'
    end
    Board.find_batches_by_global_id((top_board.settings['downstream_board_ids'] || [])[0, board_limit], batch_size: 100) do |board|
      id = board.global_id
      # also track button counts, used for board stats
      board_edit_stats[id] = board.edit_stats
      boards_with_children[id] = (board.settings['immediately_downstream_board_ids'] || [])
    end; 0
    unfound_boards += boards_with_children.map(&:last).flatten - boards_with_children.keys
    Rails.logger.info('getting all non-pre-found')
    
    
    visited_count = 0
    while !unfound_boards.empty? && visited_count < board_limit * 1.5
      batch = unfound_boards.slice(0, 200)
      unfound_boards = unfound_boards - batch
      list = []
      Octopus.using(:master) do
        list = Board.find_all_by_global_id(batch)
      end
      list = [top_board] + list if batch.include?('self')
      list.each do |board|
        visited_count += 1
        if board
          id = board.global_id
          children_ids = []
          # also track button counts, used for board stats
          board_edit_stats[id] = board.edit_stats
          downs = (board.settings['immediately_downstream_board_ids'] || [])
          downs.each do |child_id|
            children_ids << child_id
            if !boards_with_children[child_id]
              unfound_boards << child_id
            end
          end
          boards_with_children[id] = children_ids
        end
      end
    end

    Rails.logger.info('checking for downstream availability')

    # Now that we have all possible boards loaded, gather only those accessible from the root
    relevant_boards = {}
    to_visit = [top_board.global_id]
    visited = {}
    while to_visit.length > 0
      board_id = to_visit.shift
      visited[board_id] = true
      relevant_boards[board_id] = boards_with_children[board_id]
      (boards_with_children[board_id] || []).each do |down_id|
        if !visited[down_id] && !to_visit.include?(down_id)
          to_visit << down_id
        end
      end
    end

    
    # step 2: the complete downstream list is a collection of all these ids
    Rails.logger.info('generating stats and revision keys')
    # keep the closer downstream ids at the top of the list
    first_downs = []
    later_downs = []
    im_downs = (top_board.settings || {})['immediately_downstream_board_ids'] || []
    boards_with_children.each do |id, children|
      if id == 'self' || id == top_board.global_id || im_downs.include?(id)
        first_downs += children
      else
        later_downs += children
      end
    end
    downs = first_downs
    # if there are too many downstreams, limit to two levels deep for damage control
    downs += later_downs unless later_downs.length > board_limit
    downs = downs.uniq.sort - [top_board.global_id]
    downstream_ids_changed = (downs != (top_board.settings['downstream_board_ids'] || []).uniq.sort)
    total_buttons = 0
    unlinked_buttons = 0
    revision_hashes = [top_board.current_revision]
    downs.each do |id|
      if board_edit_stats[id]
        total_buttons += board_edit_stats[id]['total_buttons']
        unlinked_buttons += board_edit_stats[id]['unlinked_buttons']
        revision_hashes << board_edit_stats[id]['current_revision']
      end
    end
    downstream_boards_changed = false
    changes = {}
    full_set_revision = Digest::MD5.hexdigest(revision_hashes.join('_'))[0, 10] + "-#{revision_hashes.length}"
    if self.settings['full_set_revision'] != full_set_revision
      changes['full_set_revision'] = [self.settings['full_set_revision'], full_set_revision]
      downstream_boards_changed = true
    end
    downstream_buttons_count_changed = false
    if self.settings['total_downstream_buttons'] != total_buttons
      changes['total_downstream_buttons'] = [self.settings['total_downstream_buttons'], total_buttons]
      downstream_buttons_count_changed = true
    end
    if self.settings['unlinked_downstream_buttons'] != unlinked_buttons
      changes['unlinked_downstream_buttons'] = [self.settings['unlinked_downstream_buttons'], unlinked_buttons]
      downstream_buttons_count_changed = true
    end
    if (self.settings['downstream_board_ids'] || []).sort != downs.sort
      changes['downstream_board_ids'] = [self.settings['downstream_board_ids'], downs]
    end

    # step 3: notify upstream if there was a change
    Rails.logger.info('saving if changed')
    home_or_few_downs = self.possible_home_board? || downs.length < 100
    if downstream_ids_changed || (home_or_few_downs && downstream_buttons_count_changed) || downstream_boards_changed
      Rails.logger.info('saving because changed') if downstream_ids_changed
      Rails.logger.info('saving because buttons changed') if buttons_changed
      Rails.logger.info('saving because downstream buttons changed') if downstream_buttons_count_changed
      Rails.logger.info('saving because downstream boards changed') if downstream_boards_changed
      @track_downstream_boards = false
      board = nil
      Octopus.using(:master) do
        board = Board.find_by_global_id(self.global_id).reload
      end
      changes.each do |key, vals|
        pre, post = vals
        next if pre.to_json == post.to_json
        if board.settings[key] != pre
          Rails.logger.info("bad save, clobbering value for #{key}")
        end
        board.settings[key] = post
        self.settings[key] = post
      end
      updates = {}
      changes.each{|k, vals| updates[k] = vals[1] }
      updates['last_tracked'] = Time.now.to_i
      board.generate_stats
      board.update_setting(updates, nil, :save_without_post_processing)
      if (downstream_boards_changed || downstream_buttons_count_changed) && !downstream_ids_changed && !buttons_changed && RedisInit.queue_pressure?
        # If queues are backed up, and all that's changed is the revision hash then 
        # instead of scheduling heavy tracks for all upstream boards, just change 
        # the revision hash for all upstreams
        board.touch_upstream_revisions if downstream_boards_changed
      else
        board.complete_stream_checks(already_visited_ids + (top_board.settings['tracked_visited_ids'] || []), trigger_stamp)
      end
    end
    
    # step 4: update any authors whose list of visible/editable private boards may have changed
    Rails.logger.info('scheduling downstream update')
    if !@skip_update_available_boards
      self.schedule_update_available_boards('downstream')
    end
    @skip_update_available_boards = false
    
    Rails.logger.info('done tracking!')
    true
  end

  def possible_home_board?
    return @possible_home_board if @possible_home_board != nil
    @possible_home_board = !self.any_upstream || 
          (self.settings || {})['home_board'] || 
          (self.parent_board_id && !(self.settings || {})['copy_id']) || 
          (self.settings || {})['copy_id'] == self.global_id || 
          !!UserBoardConnection.find_by(board_id: self.id, home: true)
  end

  def touch_upstream_revisions
    upstreams = [self.global_id]
    visited_ids = []
    visited_cutoff = RedisInit.any_queue_pressure? ? LARGE_BOARD_LIST_LIMIT / 4 : LARGE_BOARD_LIST_LIMIT / 2
    while upstreams.length > 0 && visited_ids.length < visited_cutoff
      batch = upstreams[0, 20]
      upstreams = upstreams - batch
      Board.find_all_by_global_id(batch).each do |board|
        visited_ids << board.global_id
        if board != self.global_id
          rev = (board.settings['full_set_revision'] || 'na').split(/s/)[0]
          board.settings['full_set_revision'] = rev + 's' + (self.settings['full_set_revision'] || self.id.to_s)
          board.save_subtly
        end
        up_ids = board.settings['immediately_upstream_board_ids'] || []
        up_ids.each do |up_id|
          if !visited_ids.include?(up_id)
            upstreams.push(up_id)
          end
        end
      end
    end
  end
  
  def schedule_update_button_set
    return true if self.class.add_lumped_trigger({'type' => 'update_button_set', 'id' => self.global_id})
#    BoardDownstreamButtonSet.schedule_once(:update_for, self.global_id)
  end
  
  def schedule_update_available_boards(breadth='all', frd=false)
    return true if self.class.add_lumped_trigger({'type' => 'update_available_boards', 'id' => self.global_id, 'breadth' => breadth})
    return true if RedisInit.queue_pressure?
    if !frd
      ra = RemoteAction.find_by(path: self.global_id, action: 'schedule_update_available_boards')
      if ra
        if ra.extra == breadth
          # don't need to change same breadth
          RemoteAction.where(id: ra.id).update_all(act_at: 240.minutes.from_now)
        else
          RemoteAction.where(id: ra.id).update_all(act_at: 240.minutes.from_now, extra: 'all')
        end
      else
        RemoteAction.create(path: self.global_id, action: 'schedule_update_available_boards', act_at: 30.minutes.from_now, extra: breadth || 'all')
      end
#      self.schedule_once_for(:slow, :schedule_update_available_boards, breadth, true)
      return true
    end
    ids = []
    if breadth == 'all'
      ids = self.share_ids
    elsif breadth == 'downstream'
      ids = self.downstream_share_ids
    elsif breadth == 'author'
      ids = self.author_ids
    end
    User.find_all_by_global_id(ids).each do |user|
      ra_cnt = RemoteAction.where(path: "#{user.global_id}", action: 'update_available_boards').update_all(act_at: 60.minutes.from_now)
      RemoteAction.create(path: "#{user.global_id}", act_at: 30.minutes.from_now, action: 'update_available_boards') if ra_cnt == 0
    end
  end
    
  def complete_stream_checks(notify_upstream_with_visited_ids, trigger_stamp)
    # TODO: as-is this won't unlink from boards when a linked button is removed or modified
    # Step 1: reach in and add to immediately_upstream_board_ids without triggering any background processes
    downs = Board.find_all_by_global_id(self.settings['immediately_downstream_board_ids'] || [])
    downs.each do |board|
      if board && (notify_upstream_with_visited_ids || !board.settings['immediately_upstream_board_ids'] || !board.settings['immediately_upstream_board_ids'].include?(self.global_id))
        board.add_upstream_board_id!(self.global_id)
      end
    end
    # Step 2: trigger background heavy update for all immediately-upstream boards
    if notify_upstream_with_visited_ids
      depth = notify_upstream_with_visited_ids.select{|id| id.match(/depth:/) }.map{|id| id.split(/:/)[1].to_i rescue 0 }.max || 0
      strict_upstream_edits = (depth >= 5) || (depth > 1 && RedisInit.any_queue_pressure?)
      up_ids = self.settings['immediately_upstream_board_ids'] || []
      # If you have a lot of boards points to you, you're probably a home board
      # of some sort, so it's not as important that everything above you be updated
      if RedisInit.any_queue_pressure?
        up_ids = up_ids[0, 3]
      end
      Board.find_batches_by_global_id(up_ids, batch_size: 3) do |board|
        if board && !notify_upstream_with_visited_ids.include?(board.global_id)
          if trigger_stamp && board.settings['last_tracked'] && board.settings['last_tracked'] > trigger_stamp
            # if the board has been updated more recently than the current tracking sequence started, then
            # it is already up-to-date as far as this sequence is concerned, and doesn't need
            # to be re-scheduled
          elsif strict_upstream_edits && !board.possible_home_board?
            # if we've recursed many times already, and this board isn't a known
            # home board, then instead of doing all the boards, only bother
            # continuing on home boards
            new_visited_ids = (notify_upstream_with_visited_ids + [self.global_id] + ["depth:#{depth + 1}"]).uniq
            if depth < 8
              board.complete_stream_checks(new_visited_ids, trigger_stamp)
            elsif depth < 10
              board.schedule_for(:slow, :complete_stream_checks, new_visited_ids, trigger_stamp)
            end
          else
            board.reload.schedule_track(notify_upstream_with_visited_ids + ["depth:#{depth + 1}"])
            # board.schedule_once(:track_downstream_boards!, notify_upstream_with_visited_ids, nil, trigger_stamp)
          end
        end
      end
    end
  end

  def save_subtly
    was_enabled = PaperTrail.enabled?
    PaperTrail.enabled = false
    self.save_without_post_processing
    PaperTrail.enabled = was_enabled
  end

  def schedule_track(visited_ids)
    if !visited_ids.blank?
      self.settings ||= {}
      self.settings['tracked_visited_ids'] ||= []
      self.settings['tracked_visited_ids'] += visited_ids || []
      self.settings['tracked_visited_ids'].uniq!
      self.save_subtly
    end
    long_wait = self.settings['last_tracked'] && self.settings['last_tracked'] > 24.hours.ago.to_i
    existing = RemoteAction.find_by(path: self.global_id, action: 'track_downstream_with_visited')
    long_wait_cutoff = [(existing && existing.act_at) || Time.now, long_wait ? 72.hours.from_now : 120.minutes.from_now].max
    ra_cnt = RemoteAction.where(path: self.global_id, action: 'track_downstream_with_visited').update_all(act_at: long_wait_cutoff, updated_at: Time.now)
    RemoteAction.create(path: self.global_id, act_at: long_wait ? 24.hours.from_now : 30.minutes.from_now, action: 'track_downstream_with_visited') if !ra_cnt || ra_cnt == 0
  end

  def track_downstream_with_visited
    board = self
    visited_ids = board.settings['tracked_visited_ids'] || []
    board.settings.delete('tracked_visited_ids')
    board.save_subtly
    board.track_downstream_boards!(visited_ids)
  end
  
  def add_upstream_board_id!(id)
    Octopus.using(:master) do
      self.reload
    end
    self.settings ||= {}
    self.settings['immediately_upstream_board_ids'] ||= []
    self.settings['immediately_upstream_board_ids'] << id
    self.settings['immediately_upstream_board_ids'] = self.settings['immediately_upstream_board_ids'].uniq.sort
    self.update_setting('immediately_upstream_board_ids', self.settings['immediately_upstream_board_ids'], :save!)
#    BoardDownstreamButtonSet.schedule_once(:update_for, self.global_id)
  end
  
  def update_any_upstream
    self.any_upstream = (self.settings['immediately_upstream_board_ids'] || []).length > 0
    self.save_without_post_processing
  end
  
  def touch_downstreams(already_visited_ids=[])
    ids = [self.global_id] + ((self.settings || {})['downstream_board_ids'] || [])
    ids -= already_visited_ids
    # TODO: sharding
    db_ids = self.class.local_ids(ids)
    time = Time.now
    Board.where(:id => db_ids).update_all(:updated_at => time)
    ids.each{|id| UserLink.invalidate_cache_for("Board:#{id}", time.to_f) }
  end
  
  def schedule_downstream_checks(trigger_stamp)
    if @track_downstream_boards || @buttons_affecting_upstream_changed
      if trigger_stamp && self.settings['last_tracked'] && self.settings['last_tracked'] > trigger_stamp
      elsif self.possible_home_board? || !RedisInit.any_queue_pressure?
        self.schedule_track([])
      end
      @buttons_affecting_upstream_changed = nil
      @track_downstream_boards = nil
    end
  end
  
  def update_immediately_downstream_board_ids
    downs = get_immediately_downstream_board_ids
    if self.settings['immediately_downstream_board_ids'] != downs || @button_links_changed
      @track_downstream_boards = true
      @buttons_affecting_upstream_changed = @buttons_changed
      self.settings['immediately_downstream_board_ids'] = downs
    elsif @buttons_changed
      @buttons_affecting_upstream_changed = @buttons_changed
    end
  end
  
  def get_immediately_downstream_board_ids
    downs = []
    (self.grid_buttons || []).each do |button|
      if button['load_board'] && button['load_board']['id'] && button['id'] && button['load_board']['id'] != self.global_id
        if !['home', 'top board'].include?((button['label'] || 'none').downcase)
          if self.settings['copy_id'] && button['load_board']['id'] == self.settings['copy_id']
          else
            downs << button['load_board']['id']
          end
        end
      end
    end
    downs = downs.uniq.sort
  end
  

  module ClassMethods
    def lump_triggers
      @@lumped_triggers ||= []
    end
  
    def add_lumped_trigger(trigger)
      @@lumped_triggers ||= nil
      return false unless @@lumped_triggers
      @@lumped_triggers << trigger
      true
    end
  
    def process_lumped_triggers(triggers=nil)
      # NOTE: this should go away eventually. Right now if somebody updated
      # board that's linked to, say, 300 other boards, then all those boards
      # needs to have their button_set updated, and available_boards for their
      # users. If you schedule those all out, it would be 600 jobs to 
      # munge through all at once. With enough workers I guess that'd be no
      # big deal, but right now we don't have enough, so those get run
      # in a single long-running job instead.
      @@lumped_triggers ||= nil
      if !triggers && @@lumped_triggers
        if @@lumped_triggers.length > 0
          Worker.schedule_for(:slow, Board, :perform_action, {
            'method' => 'process_lumped_triggers',
            'arguments' => [@@lumped_triggers]
          })
        end
        @@lumped_triggers = nil
      end
      if triggers
        triggers.each do |trigger|
          if trigger['type'] == 'update_button_set' && trigger['id']
            # Worker.schedule_for(:slow, BoardDownstreamButtonSet, :perform_action, {
            #   'method' => 'update_for',
            #   'arguments' => [trigger['id']]
            # })
#            BoardDownstreamButtonSet.update_for(trigger['id'])
          elsif trigger['type'] == 'update_available_boards' && trigger['id']
            user = User.find_by_path(trigger['id'])
            if user
#              user.schedule_update_available_boards(trigger['breadth'], true)
              Worker.schedule_for(:slow, User, :perform_action, {
                'id' => user.id,
                'method' => 'schedule_update_available_boards',
                'arguments' => [trigger['breadth'], true]
              })
            end
          end
        end
      end
    end
  end
  
  included do
    after_create :schedule_update_available_boards
    after_destroy :schedule_update_available_boards
  end
end